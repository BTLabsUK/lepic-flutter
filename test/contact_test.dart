// Pairing with contacts between wallets on the mock chain and the mock relay: by link, by hand,
// in person and by pairing words, the words check, sealed slates, the events and the backup.
// Runs as wallet_test.dart does; from the repository root:
//   tool/lepic.sh test

import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lepic/lepic.dart';

import 'invoice_test.dart' show eventWhere;
import 'wallet_test.dart'
    show MemoryStore, epic, libraryPath, password, scanToEnd, throwsWalletError;

/// A built-in floonet relay, so pairing words are offered; the mock relay serves it.
const relayDomain = 'flooepicbox.btlabs.uk';

const online = ContactRelayMode.online;
const offline = ContactRelayMode.offline;

/// Pairs [anna] and [ben] by an invite link through the relay. Returns each side's id of the
/// other.
Future<({String annaSide, String benSide})> pairContacts(
  EpicWallet anna,
  EpicWallet ben,
) async {
  final invite = await anna.pairingInvite(
    name: 'Anna',
    kind: ContactKind.person,
    expiry: InviteExpiry.oneDay,
    offerWords: false,
    relayMode: online,
    pairingClass: PairingClass.contact,
  );
  final answer = await ben.pairingAccept(
    link: invite.link,
    name: 'Ben',
    byHand: false,
    relayMode: online,
    pairingClass: PairingClass.contact,
  );
  expect(answer.posted, isTrue);
  expect(
    (await anna.contactsCollect(
      trigger: CollectTrigger.open,
      relayMode: online,
    )).paired,
    1,
  );
  expect(
    (await ben.contactsCollect(
      trigger: CollectTrigger.open,
      relayMode: online,
    )).paired,
    1,
  );
  return (annaSide: invite.contactId, benSide: answer.contactId);
}

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
    root = Directory.systemTemp.createTempSync('lepic-contact-test-');
    chain = MockChain(height: BigInt.one);
    relay = MockRelay(chain: Chain.floonet);
    runtime = chain.runtimeWithRelay(logLevel: LogLevel.info, relay: relay);
  });

  tearDown(() async {
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    subscriptions.clear();
    root.deleteSync(recursive: true);
  });

  var wallets = 0;
  Future<EpicWallet> wallet({String? mnemonic}) async {
    wallets += 1;
    return EpicWallet.create(
      runtime: runtime,
      config: WalletConfig(
        dataDir: (Directory('${root.path}/w$wallets')..createSync()).path,
        chain: Chain.floonet,
        nodeUrl: 'http://127.0.0.1:1',
        epicboxDomain: relayDomain,
        epicboxPort: 443,
      ),
      store: lepicSecretStore(MemoryStore()),
      mnemonic: mnemonic,
      password: password,
    );
  }

  List<WalletEvent> record(EpicWallet wallet) {
    final events = <WalletEvent>[];
    subscriptions.add(wallet.events().listen(events.add));
    return events;
  }

  test(
    'two wallets pair by link, see the same words and raise events',
    () async {
      final anna = await wallet();
      final ben = await wallet();
      final annaEvents = record(anna);
      final benEvents = record(ben);

      final invite = await anna.pairingInvite(
        name: 'Anna',
        kind: ContactKind.shop,
        expiry: InviteExpiry.oneHour,
        offerWords: false,
        relayMode: online,
        pairingClass: PairingClass.contact,
      );
      expect(invite.link, startsWith('epiccash://pair/1/'));
      expect(invite.words, isEmpty);
      final pending = await anna.pairingsPending();
      expect(pending.single.contactId, invite.contactId);
      expect(pending.single.inviter, isTrue);

      final preview = await ben.pairingPreview(link: invite.link);
      expect(preview.claimedName, 'Anna');
      expect(preview.kind, ContactKind.shop);
      expect(preview.homeRelay, '$relayDomain:443');
      final answer = await ben.pairingAccept(
        link: invite.link,
        name: 'Ben',
        byHand: false,
        relayMode: online,
        pairingClass: PairingClass.contact,
      );
      await anna.contactsCollect(
        trigger: CollectTrigger.open,
        relayMode: online,
      );
      await ben.contactsCollect(
        trigger: CollectTrigger.pull,
        relayMode: online,
      );

      final replied = await eventWhere(
        annaEvents,
        (e) => e.kind == WalletEventKind.pairingReplied,
      );
      expect(replied.contactId, invite.contactId);
      final confirmed = await eventWhere(
        benEvents,
        (e) => e.kind == WalletEventKind.pairingConfirmed,
      );
      expect(confirmed.contactId, answer.contactId);

      final annaView = await anna.contact(contactId: invite.contactId);
      final benView = await ben.contact(contactId: answer.contactId);
      expect(annaView.state, PairingState.paired);
      expect(annaView.claimedName, 'Ben');
      expect(benView.kind, ContactKind.shop);
      expect(annaView.sas, hasLength(4));
      expect(annaView.sas, benView.sas);
      expect(
        [for (final c in await anna.contacts()) c.contactId],
        [invite.contactId],
      );
      expect(await anna.pairingsPending(), isEmpty);

      await anna.pairingSas(
        contactId: invite.contactId,
        decision: SasDecision.match,
        relayMode: online,
      );
      expect(
        (await anna.contact(contactId: invite.contactId)).state,
        PairingState.verified,
      );
      await ben.pairingSas(
        contactId: answer.contactId,
        decision: SasDecision.mismatch,
        relayMode: online,
      );
      await expectLater(
        ben.contact(contactId: answer.contactId),
        throwsWalletError(WalletErrorKind.contactNotFound),
      );
    },
  );

  test('a pairing by hand and one in person need no relay', () async {
    final anna = await wallet();
    final ben = await wallet();
    final invite = await anna.pairingInvite(
      name: 'Anna',
      kind: ContactKind.person,
      expiry: InviteExpiry.sevenDays,
      offerWords: false,
      relayMode: offline,
      pairingClass: PairingClass.contact,
    );
    final answer = await ben.pairingAccept(
      link: invite.link,
      name: 'Ben',
      byHand: true,
      relayMode: offline,
      pairingClass: PairingClass.contact,
    );
    expect(answer.posted, isFalse);
    final confirm = await anna.pairingEnterLink(
      text: answer.replyLink,
      relayMode: offline,
    );
    expect(confirm.outcome, PairingLinkOutcome.confirm);
    final paired = await ben.pairingEnterLink(
      text: confirm.link!,
      relayMode: offline,
    );
    expect(paired.outcome, PairingLinkOutcome.paired);
    expect(paired.contactId, answer.contactId);

    final carl = await wallet();
    final annaCard = await anna.pairingShowCard(
      name: 'Anna',
      kind: ContactKind.person,
      relayMode: offline,
    );
    final carlCard = await carl.pairingShowCard(
      name: 'Carl',
      kind: ContactKind.person,
      relayMode: offline,
    );
    final annaView = await anna.pairingScanCard(
      contactId: annaCard.contactId,
      link: carlCard.link,
      relayMode: offline,
    );
    final carlView = await carl.pairingScanCard(
      contactId: carlCard.contactId,
      link: annaCard.link,
      relayMode: offline,
    );
    expect(annaView.claimedName, 'Carl');
    expect(annaView.sas, carlView.sas);
    await expectLater(
      anna.contactsCollect(trigger: CollectTrigger.open, relayMode: offline),
      throwsWalletError(WalletErrorKind.contactsOffline),
    );
    await expectLater(
      anna.contactsCollect(
        trigger: CollectTrigger.open,
        relayMode: ContactRelayMode.epicboxOff,
      ),
      throwsWalletError(WalletErrorKind.epicboxOff),
    );
  });

  test('pairing words find the invite once', () async {
    final anna = await wallet();
    final ben = await wallet();
    final invite = await anna.pairingInvite(
      name: 'Anna',
      kind: ContactKind.person,
      expiry: InviteExpiry.oneDay,
      offerWords: true,
      relayMode: online,
      pairingClass: PairingClass.contact,
    );
    expect(invite.words, hasLength(5));
    final words = [for (final word in invite.words) word.name];
    final found = await ben.pairingFindWords(words: words, relayMode: online);
    expect(found.preview.claimedName, 'Anna');
    await expectLater(
      ben.pairingFindWords(words: words, relayMode: online),
      throwsWalletError(WalletErrorKind.pairingWordsNotFound),
    );
    await expectLater(
      ben.pairingFindWords(
        words: List.filled(5, 'nonsense'),
        relayMode: online,
      ),
      throwsWalletError(WalletErrorKind.invalidPairingWords),
    );
  });

  test('two wallets pair privately and pass payloads both ways', () async {
    final phone = await wallet();
    final desk = await wallet();
    expect(builtInPairingRelays(chain: Chain.floonet), [relayDomain]);
    await expectLater(
      phone.pairingInvite(
        name: 'Phone',
        kind: ContactKind.person,
        expiry: InviteExpiry.oneDay,
        offerWords: true,
        relayMode: online,
        pairingClass: PairingClass.private,
      ),
      throwsWalletError(WalletErrorKind.wrongPairingClass),
    );
    final invite = await phone.pairingInvite(
      name: 'Phone',
      kind: ContactKind.person,
      expiry: InviteExpiry.oneDay,
      offerWords: false,
      relayMode: online,
      pairingClass: PairingClass.private,
    );
    final preview = await desk.pairingPreview(link: invite.link);
    expect(preview.pairingClass, PairingClass.private);
    final answer = await desk.pairingAccept(
      link: invite.link,
      name: 'Desk',
      byHand: false,
      relayMode: online,
      pairingClass: PairingClass.private,
    );
    expect(answer.posted, isTrue);
    await phone.contactsCollect(
      trigger: CollectTrigger.open,
      relayMode: online,
    );
    await desk.contactsCollect(trigger: CollectTrigger.open, relayMode: online);
    final phoneSide = (await phone.privatePairings()).single;
    final deskSide = (await desk.privatePairings()).single;
    expect(phoneSide.sas, deskSide.sas);
    expect(await phone.contacts(), isEmpty);
    for (final (party, id) in [
      (phone, phoneSide.contactId),
      (desk, deskSide.contactId),
    ]) {
      await party.pairingSas(
        contactId: id,
        decision: SasDecision.match,
        relayMode: online,
      );
    }

    final id = await phone.contactPostPayload(
      contactId: phoneSide.contactId,
      payload: [1, 2, 3],
      relayMode: online,
    );
    await desk.contactsCollect(
      trigger: CollectTrigger.pull,
      relayMode: online,
      only: [deskSide.contactId],
    );
    final kept = (await desk.contactPayloads()).single;
    expect(kept.id, id);
    expect(kept.payload, [1, 2, 3]);
    expect(await desk.contactPayloadsAck(ids: [id]), 1);
    await desk.contactPostPayload(
      contactId: deskSide.contactId,
      payload: [4],
      relayMode: online,
    );
    await phone.contactsCollect(
      trigger: CollectTrigger.pull,
      relayMode: online,
    );
    expect((await phone.contactPayloads()).single.payload, [4]);
  });

  test('a contact keeps its settings and its address-book entry', () async {
    final anna = await wallet();
    final ben = await wallet();
    final ids = await pairContacts(anna, ben);
    await anna.contactSetLabel(contactId: ids.annaSide, label: 'Benjamin');
    await anna.contactSetSeal(contactId: ids.annaSide, seal: false);
    await expectLater(
      anna.contactSetAllowInvoices(contactId: ids.annaSide, allow: true),
      throwsWalletError(WalletErrorKind.contactNotVerified),
    );
    await anna.contactAttach(contactId: ids.annaSide, appContact: 'book-7');
    final view = await anna.contact(contactId: ids.annaSide);
    expect(view.label, 'Benjamin');
    expect(view.seal, SealState.off);
    expect(view.appContact, 'book-7');
    expect(
      [
        for (final c in await anna.pairingsForAppContact(appContact: 'book-7'))
          c.contactId,
      ],
      [ids.annaSide],
    );
    expect(await anna.contactRemove(contactId: ids.annaSide), isTrue);
    expect(await anna.contacts(), isEmpty);
    await expectLater(
      anna.pairingCancel(contactId: ids.annaSide),
      throwsWalletError(WalletErrorKind.pairingNotFound),
    );
  });

  test('a sealed payment goes there and back by paste', () async {
    final anna = await wallet();
    chain.fund(
      mnemonic: await anna.mnemonic(password: password),
      chain: Chain.floonet,
      amount: BigInt.from(10 * epic),
      child: 0,
    );
    chain.setHeight(height: BigInt.from(20));
    await scanToEnd(anna);
    final ben = await wallet();
    final ids = await pairContacts(anna, ben);

    final slate = await anna.createSendSlate(
      amount: BigInt.from(epic),
      minimumConfirmations: BigInt.one,
    );
    final sealed = await anna.contactSealSlate(
      contactId: ids.annaSide,
      txId: slate.txId,
    );
    expect(sealed, isNot(contains(slate.slateId)));
    final opened = await ben.sealedOpen(text: sealed);
    expect(opened.contactId, ids.benSide);
    expect(opened.stage, SlateStage.s1);
    expect(opened.amount, BigInt.from(epic));
    expect(opened.purpose, SlatePurpose.payment);
    final answer = await ben.sealedReceive(text: sealed);
    expect(answer.sealed, isTrue);
    final finalized = await anna.sealedFinalize(text: answer.answer);
    expect(finalized.txId, slate.txId);
    expect(chain.pushedCount(), 1);
    expect(await anna.contactOfTransaction(txId: slate.txId), ids.annaSide);
    await expectLater(
      anna.sealedOpen(text: 'not sealed'),
      throwsWalletError(WalletErrorKind.invalidPairingText),
    );
  });

  test('the backup brings the pairings back on another install', () async {
    final anna = await wallet();
    final ben = await wallet();
    final ids = await pairContacts(anna, ben);
    final document = await anna.contactsExport();
    final restored = await wallet(
      mnemonic: await anna.mnemonic(password: password),
    );
    final summary = await restored.contactsImport(document: document);
    expect(summary.imported, 1);
    final view = await restored.contact(contactId: ids.annaSide);
    expect(view.importedFromBackup, isTrue);
    expect(view.sas, (await anna.contact(contactId: ids.annaSide)).sas);
  });
}
