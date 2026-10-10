/// A tiny command language for poking an unknown panel by hand.
///
/// Written for trial and error on hardware: scripts live in a text file pushed to the phone with
/// `adb`, so changing the experiment never needs a rebuild. One step per line:
///
/// ```
/// # comment                      ignored, as are blank lines
/// tech nfcA                      which interface to open (default isoDep); first line only matters
/// 00 A4 04 00 07 D2 76 00 00 85 01 01
/// delay 50                       milliseconds
/// fill F0 D2 00 00 FA : FF x 250 a header, then one byte repeated — for data blocks
/// stop-unless 9000               abort the run unless the last reply ended with this status
/// ```
library;

sealed class ProbeStep {
  const ProbeStep();
}

class SendStep extends ProbeStep {
  const SendStep(this.bytes);
  final List<int> bytes;
}

class DelayStep extends ProbeStep {
  const DelayStep(this.duration);
  final Duration duration;
}

/// Stops the run unless the previous reply ended with [suffix] (hex, case-insensitive).
class StopUnlessStep extends ProbeStep {
  const StopUnlessStep(this.suffix);
  final String suffix;
}

class ProbeScript {
  const ProbeScript({required this.tech, required this.steps});

  final String tech;
  final List<ProbeStep> steps;

  static ProbeScript parse(String source) {
    var tech = 'isoDep';
    final steps = <ProbeStep>[];

    final lines = source.split('\n');
    for (var n = 0; n < lines.length; n++) {
      final line = lines[n].split('#').first.trim();
      if (line.isEmpty) continue;
      final words = line.split(RegExp(r'\s+'));

      switch (words.first.toLowerCase()) {
        case 'tech':
          tech = words.elementAtOrNull(1) ?? tech;
        case 'delay':
          final ms = int.tryParse(words.elementAtOrNull(1) ?? '');
          if (ms == null) {
            throw FormatException('Line ${n + 1}: delay needs ms');
          }
          steps.add(DelayStep(Duration(milliseconds: ms)));
        case 'stop-unless':
          final sw = words.elementAtOrNull(1);
          if (sw == null) {
            throw FormatException('Line ${n + 1}: stop-unless needs a status');
          }
          steps.add(StopUnlessStep(sw.toUpperCase()));
        case 'fill':
          steps.add(SendStep(_fill(line.substring(4), n + 1)));
        default:
          steps.add(SendStep(_hex(words, n + 1)));
      }
    }
    return ProbeScript(tech: tech, steps: steps);
  }

  /// `<header hex> : <byte> x <count>`
  static List<int> _fill(String rest, int lineNo) {
    final parts = rest.split(':');
    final body = parts.length == 2
        ? RegExp(r'^\s*([0-9A-Fa-f]{2})\s*x\s*(\d+)\s*$').firstMatch(parts[1])
        : null;
    if (body == null) {
      throw FormatException(
        'Line $lineNo: fill is "<header> : <byte> x <count>"',
      );
    }
    final header = _hex(parts[0].trim().split(RegExp(r'\s+')), lineNo);
    final byte = int.parse(body.group(1)!, radix: 16);
    final count = int.parse(body.group(2)!);
    return [...header, ...List.filled(count, byte)];
  }

  static List<int> _hex(List<String> words, int lineNo) {
    // Accept both "00 A4 04" and "00A404".
    final joined = words.join();
    if (joined.length.isOdd || !RegExp(r'^[0-9A-Fa-f]+$').hasMatch(joined)) {
      throw FormatException('Line $lineNo: not hex: ${words.join(' ')}');
    }
    return [
      for (var i = 0; i < joined.length; i += 2)
        int.parse(joined.substring(i, i + 2), radix: 16),
    ];
  }
}
