// 提示条状态：同屏最多 3 条、默认 3200ms、同 key 只留一条并重新计时、同文案去重。
// 规则逐条对译 src/state/toast.tsx。
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/state/toast_state.dart';

void main() {
  test('同 key 只留一条并重新计时', () {
    final state = ToastState();
    addTearDown(state.dispose);
    state.show('列表循环', key: 'mode');
    final first = state.items.single;
    state.show('单曲循环', key: 'mode');
    expect(state.items.length, 1);
    expect(state.items.single.message, '单曲循环');
    expect(state.items.single.id, first.id); // 复用同一条，不新增
    expect(first.createdAt, isNot(state.items.single.createdAt)); // 重新计时
  });

  test('同文案不同 key 也去重', () {
    final state = ToastState();
    addTearDown(state.dispose);
    state.show('已清空', key: 'a');
    state.show('已清空', key: 'b');
    expect(state.items.length, 1);
  });

  test('超出 3 条时排队，前面的消失后才补上', () {
    final state = ToastState();
    addTearDown(state.dispose);
    for (var i = 0; i < 5; i++) {
      state.show('消息$i', key: 'k$i', durationMs: 10);
    }
    expect(state.items.length, 3);
    expect(state.queued.length, 2);
    state.drainForTest();
    expect(state.items.length, 3);
    state.drainForTest();
    expect(state.items.length, 3);
    state.drainForTest();
    expect(state.items.length, 2);
  });

  test('dismiss 后从队列补一条', () {
    final state = ToastState();
    addTearDown(state.dispose);
    for (var i = 0; i < 4; i++) {
      state.show('消息$i', key: 'k$i', durationMs: 1000);
    }
    state.dismiss(state.items.first.id);
    expect(state.items.map((e) => e.message), ['消息1', '消息2', '消息3']);
  });

  test('info/error 走各自 kind 且默认时长 3200', () {
    final state = ToastState();
    addTearDown(state.dispose);
    state.info('提示');
    state.error('失败');
    expect(state.items.first.kind, ToastKind.info);
    expect(state.items.last.kind, ToastKind.error);
    expect(state.items.first.durationMs, 3200);
  });

  test('notifyListeners 每次变更恰好一次', () {
    final state = ToastState();
    addTearDown(state.dispose);
    var count = 0;
    state.addListener(() => count++);
    state.show('a', key: 'x');
    expect(count, 1);
    state.show('b', key: 'x');
    expect(count, 2);
  });
}
