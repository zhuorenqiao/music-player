/**
 * async-limit.js —— 一个很小的并发闸门
 *
 * 为什么需要它：大文件夹导入会把每一首的标签读取、时长探针一次性全部发起。
 * 2000 个 `arrayBuffer` / `HTMLAudioElement` 叠在一起，浏览器主线程和内存都
 * 会受不了（移动端 Chrome 直接掉帧甚至被系统回收）。这里给每条链路一个固定
 * 额度，完成一条再补一条，峰值从 N 首降到 N 个并发的固定上限。
 *
 * 语义：`createLimiter(n)` 返回的 run(task) **不丢弃任务**，只是排队；返回的
 * Promise 与直接执行 task 等价（包括 rejects）。许可直接移交给等待者，不会
 * 出现「释放后新来的任务抢走许可、被唤醒的等待者又多占一个」的超发。
 */

/**
 * @param {number} limit 同时执行的上限（至少 1）
 * @returns {<T>(task: () => Promise<T> | T) => Promise<T>} 带闸门的执行器
 */
export function createLimiter(limit) {
  const max = Math.max(1, Math.floor(Number(limit) || 1));
  let active = 0;
  /** @type {Array<() => void>} */
  const queue = [];

  return async function run(task) {
    while (active >= max) {
      await new Promise((resolve) => {
        queue.push(resolve);
      });
    }
    active += 1;
    try {
      return await task();
    } finally {
      active -= 1;
      const next = queue.shift();
      if (next) {
        next();
      }
    }
  };
}

/**
 * 以固定并发跑完一批任务，返回与输入同序的结果。
 * @template T, R
 * @param {T[]} items
 * @param {number} limit
 * @param {(item: T, index: number) => Promise<R> | R} task
 * @returns {Promise<R[]>}
 */
export async function mapWithConcurrency(items, limit, task) {
  const run = createLimiter(limit);
  return Promise.all(items.map((item, index) => run(() => task(item, index))));
}
