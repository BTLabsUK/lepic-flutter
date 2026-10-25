// Invoices between paired contacts on the mock chain and the mock relay: issued, paid with the
// typed amount, declined and expired. Runs as wallet_test.dart does; from the repository root:
//   tool/lepic.sh test

import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lepic/lepic.dart';

import 'contact_test.dart' show online, pairContacts, relayDomain;
import 'wallet_test.dart'
    show
        MemoryStore,
        bobPhrase,
        epic,
        libraryPath,
        password,
        scanToEnd,
        throwsWalletError;

/// Waits until [events] holds an event that [matches], and returns it.
Future<WalletEvent> eventWhere(
  List<WalletEvent> events,
  bool Function(WalletEvent) matches,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    for (final event in events) {
      if (matches(event)) return event;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw TimeoutException('no matching event in $events');
}

typedef Parties = ({
  EpicWallet payer,
  EpicWallet issuer,

  /// The payer's id of the issuer.
  String payerSide,

  /// The issuer's id of the payer.
  String issuerSide,
  List<WalletEvent> payerEvents,
  List<WalletEvent> issuerEvents,
});

void main() {
  late Directory root;
  late MockChain chain;
  late MockRelay relay;
  late LepicRuntime runtime;
  final subscriptions = <StreamSubscription<WalletEvent>>[];

  setUpAll(() async {
    await RustLib.init(externalLibrary: ExternalLibrary.open(libraryPath()));
  });

  setUp(() {
    root = Directory.systemTemp.createTempSync('lepic-invoice-test-');
    chain = MockChain(height: BigInt.one);
    relay = MockRelay(chain: Chain.floonet);
    runtime = chain.runtimeWithRelay(logLevel: LogLevel.info, relay: relay);
  });

  tearDown(() async {
    // A wallet's event stream ends only when the wallet is dropped, so cancelling waits for
    // that; the cancels finish once the test's wallets are gone.
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    subscriptions.clear();
    root.deleteSync(recursive: true);
  });

  WalletConfig relayConfig(String name) => WalletConfig(
    dataDir: (Directory('${root.path}/$name')..createSync()).path,
    chain: Chain.floonet,
    nodeUrl: 'http://127.0.0.1:1',
    epicboxDomain: relayDomain,
    epicboxPort: 443,
  );

  List<WalletEvent> record(EpicWallet wallet) {
    final events = <WalletEvent>[];
    subscriptions.add(wallet.events().listen(events.add));
    return events;
  }

  /// A payer with 10 EPIC and the issuer, paired and verified on both sides, the payer
  /// allowing the issuer's invoices.
  Future<Parties> parties(String name) async {
    final payer = await EpicWallet.create(
      runtime: runtime,
      config: relayConfig('$name-payer'),
      store: lepicSecretStore(MemoryStore()),
      password: password,
    );
    chain.fund(
      mnemonic: await payer.mnemonic(password: password),
      chain: Chain.floonet,
      amount: BigInt.from(10 * epic),
      child: 0,
    );
    chain.setHeight(height: BigInt.from(20));
    await scanToEnd(payer);
    final issuer = await EpicWallet.create(
      runtime: runtime,
      config: relayConfig('$name-issuer'),
      store: lepicSecretStore(MemoryStore()),
      mnemonic: bobPhrase,
      password: password,
    );
    await scanToEnd(issuer);
    final ids = await pairContacts(issuer, payer);
    for (final (wallet, id) in [(issuer, ids.annaSide), (payer, ids.benSide)]) {
      await wallet.pairingSas(
        contactId: id,
        decision: SasDecision.match,
        relayMode: online,
      );
    }
    await payer.contactSetAllowInvoices(contactId: ids.benSide, allow: true);
    return (
      payer: payer,
      issuer: issuer,
      payerSide: ids.benSide,
      issuerSide: ids.annaSide,
      payerEvents: record(payer),
      issuerEvents: record(issuer),
    );
  }

  /// The issuer invoices 3 EPIC and the payer's collect parks it.
  Future<(IssuedInvoice, ContactInvoiceView)> parked(Parties p) async {
    final issued = await p.issuer.contactIssueInvoice(
      contactId: p.issuerSide,
      amount: BigInt.from(3 * epic),
      message: 'order 42',
      purpose: SlatePurpose.depositRequest,
      reference: 'order 42',
      relayMode: online,
    );
    await p.payer.contactsCollect(
      trigger: CollectTrigger.open,
      relayMode: online,
    );
    final waiting = await p.payer.contactInvoices();
    expect(waiting, hasLength(1));
    return (issued, waiting.single);
  }

  test('an invoice from a contact waits, is paid with the typed amount and finalized', () async {
    final p = await parties('paid');
    final (issued, invoice) = await parked(p);
    expect(issued.amount, BigInt.from(3 * epic));
    final waiting = await p.issuer.transaction(txId: issued.txId);
    expect(waiting.direction, TxDirection.incoming);
    expect(waiting.flow, TxFlow.invoice);
    expect(invoice.slateId, issued.slateId);
    expect(invoice.contactId, p.payerSide);
    expect(invoice.amount, BigInt.from(3 * epic));
    expect(invoice.purpose, SlatePurpose.depositRequest);
    expect(invoice.reference, 'order 42');
    final received = await eventWhere(
      p.payerEvents,
      (e) => e.kind == WalletEventKind.invoiceFromContact,
    );
    expect(received.slateId, issued.slateId);
    expect(received.contactId, p.payerSide);
    expect(received.amount, BigInt.from(3 * epic));
    expect(received.purpose, SlatePurpose.depositRequest);

    await expectLater(
      p.payer.contactPayInvoice(
        slateId: issued.slateId,
        amount: BigInt.from(2 * epic),
        minimumConfirmations: BigInt.one,
        relayMode: online,
      ),
      throwsWalletError(WalletErrorKind.amountMismatch),
    );
    final paid = await p.payer.contactPayInvoice(
      slateId: issued.slateId,
      amount: BigInt.from(3 * epic),
      minimumConfirmations: BigInt.one,
      relayMode: online,
    );
    expect(paid.slateId, issued.slateId);
    expect(paid.amount, BigInt.from(3 * epic));
    expect(paid.fee, greaterThan(BigInt.zero));
    final payment = await p.payer.transaction(txId: paid.txId);
    expect(payment.direction, TxDirection.outgoing);
    expect(payment.flow, TxFlow.invoice);
    expect(await p.payer.contactInvoices(), isEmpty);
    await expectLater(
      p.payer.contactPayInvoice(
        slateId: issued.slateId,
        amount: BigInt.from(3 * epic),
        minimumConfirmations: BigInt.one,
        relayMode: online,
      ),
      throwsWalletError(WalletErrorKind.invoiceNotFound),
    );
    final outbox = await p.payer.contactOutbox(contactId: p.payerSide);
    expect(
      outbox.where((entry) => entry.slateId == issued.slateId).single.state,
      OutboxState.delivered,
    );

    await p.issuer.contactsCollect(
      trigger: CollectTrigger.open,
      relayMode: online,
    );
    expect(chain.pushedCount(), 1);
    expect(
      (await p.issuer.transaction(txId: issued.txId)).status,
      TxStatus.posted,
    );
  });

  test(
    'an unpaid invoice is not money on its way until its payment is finalized',
    () async {
      final p = await parties('figures');
      final (issued, _) = await parked(p);

      Future<WalletOutput> invoiceOutput() async => (await p.issuer.outputs())
          .singleWhere((output) => output.txId == issued.txId);
      final unpaid = await invoiceOutput();
      expect(unpaid.category, OutputCategory.unpaidInvoice);
      expect(unpaid.value, BigInt.from(3 * epic));
      final before = await p.issuer.summary(refresh: false);
      expect(before.awaitingFinalization, BigInt.zero);
      expect(before.total, BigInt.zero);

      await p.payer.contactPayInvoice(
        slateId: issued.slateId,
        amount: BigInt.from(3 * epic),
        minimumConfirmations: BigInt.one,
        relayMode: online,
      );
      // Paid, but the issuer has not collected the payment yet.
      expect((await invoiceOutput()).category, OutputCategory.unpaidInvoice);
      await p.issuer.contactsCollect(
        trigger: CollectTrigger.open,
        relayMode: online,
      );

      expect(
        (await invoiceOutput()).category,
        OutputCategory.awaitingFinalization,
      );
      final after = await p.issuer.summary(refresh: false);
      expect(after.awaitingFinalization, BigInt.from(3 * epic));
    },
  );

  test('a declined invoice is never paid and the issuer hears of it', () async {
    final p = await parties('declined');
    final (issued, _) = await parked(p);

    await p.payer.contactDeclineInvoice(slateId: issued.slateId);
    expect(await p.payer.contactInvoices(), isEmpty);
    await expectLater(
      p.payer.contactPayInvoice(
        slateId: issued.slateId,
        amount: BigInt.from(3 * epic),
        minimumConfirmations: BigInt.one,
        relayMode: online,
      ),
      throwsWalletError(WalletErrorKind.invoiceNotFound),
    );
    await expectLater(
      p.payer.contactDeclineInvoice(slateId: issued.slateId),
      throwsWalletError(WalletErrorKind.invoiceNotFound),
    );
    await expectLater(
      p.payer.contactDeclineInvoice(slateId: 'not-a-slate-id'),
      throwsWalletError(WalletErrorKind.invalidArgument),
    );
    await p.payer.contactsOutboxDeliver(relayMode: online);
    await p.issuer.contactsCollect(
      trigger: CollectTrigger.open,
      relayMode: online,
    );
    final declined = await eventWhere(
      p.issuerEvents,
      (e) => e.kind == WalletEventKind.invoiceDeclined,
    );
    expect(declined.txId, issued.txId);
    expect(declined.slateId, issued.slateId);
    expect(
      (await p.issuer.transaction(txId: issued.txId)).status,
      TxStatus.received,
    );
  });

  test('invoices from a contact that is not allowed never wait', () async {
    final p = await parties('not-allowed');
    await p.payer.contactSetAllowInvoices(contactId: p.payerSide, allow: false);
    await p.issuer.contactIssueInvoice(
      contactId: p.issuerSide,
      amount: BigInt.from(epic),
      purpose: SlatePurpose.request,
      relayMode: online,
    );
    await p.payer.contactsCollect(
      trigger: CollectTrigger.open,
      relayMode: online,
    );
    expect(await p.payer.contactInvoices(), isEmpty);
    expect(
      p.payerEvents.where((e) => e.kind == WalletEventKind.invoiceFromContact),
      isEmpty,
    );
  });

  test('a sweep expires unpaid invoices on both sides', () async {
    final p = await parties('expiry');
    final (issued, _) = await parked(p);
    for (final invalid in [0, 48 * 3600 + 1]) {
      await expectLater(
        p.payer.sweepInvoices(expirySecs: BigInt.from(invalid)),
        throwsWalletError(WalletErrorKind.invalidArgument),
      );
    }
    final kept = await p.payer.sweepInvoices();
    expect(kept.deleted, isEmpty);
    expect(await p.payer.contactInvoices(), hasLength(1));

    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final payerSweep = await p.payer.sweepInvoices(expirySecs: BigInt.one);
    expect(payerSweep.deleted, [issued.slateId]);
    expect(await p.payer.contactInvoices(), isEmpty);
    final deleted = await eventWhere(
      p.payerEvents,
      (e) => e.kind == WalletEventKind.invoiceExpired,
    );
    expect(deleted.slateId, issued.slateId);
    expect(deleted.txId, isNull);

    final issuerSweep = await p.issuer.sweepInvoices(expirySecs: BigInt.one);
    expect(issuerSweep.cancelled, [issued.txId]);
    expect(
      (await p.issuer.transaction(txId: issued.txId)).status,
      TxStatus.cancelled,
    );
    final cancelled = await eventWhere(
      p.issuerEvents,
      (e) => e.kind == WalletEventKind.invoiceExpired,
    );
    expect(cancelled.slateId, issued.slateId);
    expect(cancelled.txId, issued.txId);
  });

  test('errors of the invoice calls carry their stable codes', () async {
    final wallet = await EpicWallet.create(
      runtime: runtime,
      config: relayConfig('codes'),
      store: lepicSecretStore(MemoryStore()),
      password: password,
    );
    await expectLater(
      wallet.contactPayInvoice(
        slateId: '0436430c-2b02-624c-2032-570501212b0e',
        amount: BigInt.from(epic),
        minimumConfirmations: BigInt.one,
        relayMode: online,
      ),
      throwsWalletError(WalletErrorKind.invoiceNotFound),
    );
    wallet.lock();
    await expectLater(
      wallet.contactInvoices(),
      throwsWalletError(WalletErrorKind.locked),
    );
  });
}
