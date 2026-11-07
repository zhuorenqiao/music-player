// test/core/format_time_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/format_time.dart';

void main() {
  test('未知时长一律 --:--', () {
    expect(formatTime(null), '--:--');
    expect(formatTime(double.nan), '--:--');
    expect(formatTime(double.infinity), '--:--');
    expect(formatTotal(double.nan), '--:--');
  });

  test('mm:ss 补零并向下取整', () {
    expect(formatTime(0), '00:00');
    expect(formatTime(9.9), '00:09');
    expect(formatTime(65), '01:05');
    expect(formatTime(600.7), '10:00');
  });

  test('超过一小时带小时位', () {
    expect(formatTotal(3599), '59:59');
    expect(formatTotal(3600), '1:00:00');
    expect(formatTotal(3725), '1:02:05');
  });

  test('负数按 0 处理', () {
    expect(formatTime(-3), '00:00');
  });
}
