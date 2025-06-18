/**
 * 节流 在规定的时间内，只执行一次
 *
 */
export function throttle(func: (event: ClickEvent) => void, delay?: number) {
  let inThrottle: boolean;
  return (event: ClickEvent) => {
    if (!inThrottle) {
      func(event);
      inThrottle = true;
      setTimeout(() => inThrottle = false, delay ? delay : 1000);
    }
  };
}