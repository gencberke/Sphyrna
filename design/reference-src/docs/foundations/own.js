sea('ocean-school', { cell: 11, alpha: .6, specs: [{ kind: 'hammerhead', L: 470, depth: .85, speed: 16 }, { kind: 'hammerhead', L: 290, depth: .5, speed: 12 }, { kind: 'thresher', L: 320, depth: .75, speed: 21 }, { kind: 'whale', L: 820, depth: .3, speed: 8 }] });
// A shark swimming in place: the cast, the empty panes and the waiting one.
const inPlace = (kind, L, cell) => ({ cell, fps: 12, alpha: .72, plankton: 0, wake: false, specs: [{ kind, L, depth: 1, speed: 0, fx: .5, fy: .5, angle: 0, center: true }] });
sea('cast-hammerhead', inPlace('hammerhead', 230, 8));
sea('cast-thresher', inPlace('thresher', 160, 8));
sea('cast-remora', inPlace('remora', 170, 8));
sea('cast-whale', inPlace('whale', 240, 8));
sea('empty-agents', inPlace('hammerhead', 130, 6));
sea('empty-changes', inPlace('thresher', 92, 6));
sea('wait-branch', inPlace('hammerhead', 100, 6));
document.addEventListener('visibilitychange', () => oceans.forEach(o => o.sync()));
reduceMotion.addEventListener('change', () => oceans.forEach(o => o.sync()));
