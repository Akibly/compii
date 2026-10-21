// Live check of the phone remote against a running Compii Core (rehearsal brain).
// Skipped unless COMPII_LIVE_LINK holds a fresh pairing link from POST /pair/start.
import 'dart:io';

import 'package:compii/src/console/core_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final linkText = Platform.environment['COMPII_LIVE_LINK'];

  test('a wrong fingerprint is refused before anything is sent', () async {
    final invite = PairingInvite.parse(linkText!)!;
    final fake = PairingInvite(host: invite.host, port: invite.port, code: invite.code, fingerprint: 'ab' * 32, pc: invite.pc);
    await expectLater(fake.claim('Impostor test'), throwsA(isA<CoreError>()));
  }, skip: linkText == null);

  test('pair, follow a task and approve it from the phone', () async {
    final invite = PairingInvite.parse(linkText!)!;
    final link = await invite.claim('Live test phone');
    expect(link.token, isNotEmpty);

    final core = CoreClient(remote: link)..start();
    addTearDown(core.dispose);
    Future<void> until(bool Function() ok, String what, {int seconds = 20}) async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (!ok()) {
        if (DateTime.now().isAfter(end)) fail('Timed out waiting for $what');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    await until(() => core.status == CoreStatus.online, 'connection');
    final id = await core.startConversation('Make my invoice spreadsheet and email it');
    await until(() => core.tasks[id]?.pendingApproval != null, 'the email approval');
    final approval = core.tasks[id]!.pendingApproval!;
    expect(approval['label'], isNotEmpty);
    await core.decide('${approval['approval_id']}', approved: true);
    await until(() => core.tasks[id]?.active == false, 'the task to finish');
    expect(core.tasks[id]!.finalText, contains('spreadsheet'));

    // Pairing endpoints stay PC-only.
    await expectLater(core.pairStart(), throwsA(isA<CoreError>()));
  }, skip: linkText == null, timeout: const Timeout(Duration(seconds: 60)));
}
