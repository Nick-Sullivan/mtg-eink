import 'package:epaper_nfc/epaper_nfc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses commands, delays, guards and comments', () {
    final script = ProbeScript.parse('''
# select
tech nfcA
00 A4 04 00   # trailing comment
00a404
delay 50

stop-unless 9000
''');

    expect(script.tech, 'nfcA');
    expect(script.steps, hasLength(4));
    expect((script.steps[0] as SendStep).bytes, [0x00, 0xA4, 0x04, 0x00]);
    expect((script.steps[1] as SendStep).bytes, [0x00, 0xA4, 0x04]);
    expect((script.steps[2] as DelayStep).duration.inMilliseconds, 50);
    expect((script.steps[3] as StopUnlessStep).suffix, '9000');
  });

  test('fill builds a header followed by a repeated byte', () {
    final script = ProbeScript.parse('fill F0 D2 00 01 FA : ff x 250');
    final bytes = (script.steps.single as SendStep).bytes;

    expect(bytes, hasLength(255));
    expect(bytes.sublist(0, 5), [0xF0, 0xD2, 0x00, 0x01, 0xFA]);
    expect(bytes.skip(5).every((b) => b == 0xFF), isTrue);
  });

  test('defaults to IsoDep and rejects junk', () {
    expect(ProbeScript.parse('00').tech, 'isoDep');
    expect(() => ProbeScript.parse('0G'), throwsFormatException);
    expect(() => ProbeScript.parse('ABC'), throwsFormatException);
    expect(() => ProbeScript.parse('delay soon'), throwsFormatException);
  });
}
