// SPDX-License-Identifier: Apache-2.0
import 'package:lepic/lepic.dart';

/// The tuning keys of the app's shipped app-config.toml, for the tests: LEPIC has no defaults.
const shippedTuning = NetTuning(
  node: NodeTuning(
    connectTimeoutS: 15,
    requestTimeoutS: 90,
    idleTimeoutS: 10,
    retryAttempts: 3,
    retryBackoffMinMs: 500,
    retryBackoffMaxMs: 4000,
    outputsPerRequest: 500,
    concurrentRequests: 4,
  ),
  epicbox: EpicboxTuning(
    connectTimeoutS: 15,
    responseTimeoutS: 15,
    pingIntervalS: 25,
    reconnectMinS: 1,
    reconnectMaxS: 60,
    drainTimeoutS: 120,
    torConnectTimeoutS: 90,
    onionDiscoveryTimeoutS: 45,
    onionDiscoveryRetryS: 600,
  ),
  http: HttpTuning(
    headerTimeoutS: 10,
    bodyTimeoutS: 15,
    requestTimeoutS: 60,
    answerTimeoutS: 10,
    maxConnections: 16,
    maxConnectionsPerAddress: 4,
    requestsPerMinute: 120,
    receivesPerMinute: 30,
    sendConnectTimeoutS: 10,
    sendRequestTimeoutS: 60,
  ),
  tor: TorTuning(
    bootstrapTimeoutS: 120,
    coldBootstrapTimeoutS: 240,
    stallTimeoutS: 60,
    coldStallTimeoutS: 120,
    publishTimeoutS: 180,
    connectTimeoutS: 75,
    requestTimeoutS: 120,
  ),
);
