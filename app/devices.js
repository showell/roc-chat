// This script runs on the device code page, /devices, which
// app/DeviceCodePage.roc builds and app/Script.roc serves. panel.js styles
// the page; this script makes it live.
//
// A code's expiry (.code-expiry, a <time datetime>) is shown in the viewer's
// own zone, with the minutes and seconds left, and when none are left the
// code goes from the page. The status line (.code-status) names the
// viewer's stream (data-stream): its `device-used` event says the code was
// used, at the moment its data holds, and the code and its cancel button go.
// Leaving the page (pagehide) takes the code off it, so the browser's
// back-forward cache never shows it again.
(function () {
  'use strict';
  var status = document.querySelector('.code-status');
  var expiry = document.querySelector('.code-expiry');
  var timer = null;

  function localTime(moment) {
    return moment.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  }

  function forgetCode() {
    var code = document.querySelector('.sign-in-code');
    if (code) code.remove();
    var cancel = document.querySelector('form[action="/devices/cancel"]');
    if (cancel) cancel.remove();
    if (timer !== null) clearInterval(timer);
    timer = null;
  }

  if (expiry) {
    var until = new Date(expiry.getAttribute('datetime'));
    var tick = function () {
      var left = Math.max(0, Math.round((until.getTime() - Date.now()) / 1000));
      if (left === 0) {
        expiry.textContent = localTime(until);
        forgetCode();
        if (status) status.textContent = 'The code has expired. Make a new one to sign a device in.';
        return;
      }
      var seconds = String(left % 60);
      if (seconds.length < 2) seconds = '0' + seconds;
      expiry.textContent = localTime(until) + ' (' + Math.floor(left / 60) + ':' + seconds + ' left)';
    };
    tick();
    timer = setInterval(tick, 1000);
  }

  if (status && typeof EventSource !== 'undefined') {
    var stream = new EventSource(status.getAttribute('data-stream'));
    stream.addEventListener('device-used', function (event) {
      forgetCode();
      var at = new Date(event.data);
      status.textContent = 'Your code signed a device in at ' + localTime(at) + '.';
    });
    window.addEventListener('pagehide', function () { stream.close(); });
  }

  window.addEventListener('pagehide', forgetCode);
})();
