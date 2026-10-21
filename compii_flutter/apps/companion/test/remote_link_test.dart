import 'package:compii/src/console/core_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const fp = 'ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12';

  test('a pairing link carries every address, home first', () {
    final invite = PairingInvite.parse('compii://pair?h=192.168.1.20&p=8766&c=ABCD-EFGH&f=$fp&n=Desk&a=100.101.7.8%2Chome.example.net')!;
    expect(invite.hosts, ['192.168.1.20', '100.101.7.8', 'home.example.net']);
    final old = PairingInvite.parse('compii://pair?h=192.168.1.20&p=8766&c=ABCD-EFGH&f=$fp&n=Desk')!;
    expect(old.hosts, ['192.168.1.20']);
  });

  test('a saved link keeps its addresses, and old saves still load', () {
    const link = RemoteLink(host: '192.168.1.20', port: 8766, fingerprint: fp, token: 't', pc: 'Desk',
        hosts: ['192.168.1.20', '100.101.7.8']);
    final back = RemoteLink.fromJson(Map<String, dynamic>.from(link.toJson()));
    expect(back.hosts, ['192.168.1.20', '100.101.7.8']);
    final legacy = RemoteLink.fromJson({'host': '10.0.0.5', 'port': 8766, 'fingerprint': fp, 'token': 't'});
    expect(legacy.hosts, ['10.0.0.5']);
    expect(link.withHosts(['100.101.7.8', '192.168.1.20']).host, '100.101.7.8');
  });

  test('Tailscale-style addresses are recognised as reachable from anywhere', () {
    expect(isOverlayAddress('100.101.7.8'), isTrue);
    expect(isOverlayAddress('100.64.0.1'), isTrue);
    expect(isOverlayAddress('100.128.0.1'), isFalse);
    expect(isOverlayAddress('192.168.1.20'), isFalse);
    expect(isOverlayAddress('home.example.net'), isFalse);
  });
}
