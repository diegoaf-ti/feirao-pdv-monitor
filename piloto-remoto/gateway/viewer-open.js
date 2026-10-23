'use strict';
(() => {
  const target = document.getElementById('continue')?.getAttribute('href');
  if (/^\/pdv-remote\/s\/[0-9a-f-]{36}\/$/.test(target || '')) window.location.replace(target);
})();
