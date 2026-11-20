// This script runs on the device code page, /devices, which
// app/DeviceCodePage.roc builds and app/Script.roc serves. panel.js styles
// the page; this script centres it, as recent.js centres Recent's, sets its
// numbered steps apart with the sign-in page's address large, and makes it
// live.
//
// Each sign-in by code's time (a <time datetime> in the list) is said as
// how long ago it was, "12 minutes ago", never the raw time; its title
// keeps the moment in the viewer's own zone.
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

  // panel.js runs after this script and styles each element in place, so a
  // rule here that must win over its says so.
  var s = document.createElement('style');
  s.textContent = ''
    + '.panel { margin-left:auto; margin-right:auto; }'
    + '.panel ol { margin:12px 0; padding-left:24px; }'
    + '.panel ol > li { margin:0 0 18px; padding-left:4px; font-size:15px; }'
    + '.panel ol > li::marker { font-weight:bold; }'
    + '.panel ol .invite-code { font-size:18px !important; }';
  document.head.appendChild(s);

  function ago(moment) {
    var minutes = Math.round((Date.now() - moment.getTime()) / 60000);
    if (minutes < 1) return 'just now';
    if (minutes < 60) return minutes + (minutes === 1 ? ' minute ago' : ' minutes ago');
    var hours = Math.round(minutes / 60);
    if (hours < 24) return hours + (hours === 1 ? ' hour ago' : ' hours ago');
    var days = Math.round(hours / 24);
    return days + (days === 1 ? ' day ago' : ' days ago');
  }
  document.querySelectorAll('li > time[datetime]').forEach(function (element) {
    var moment = new Date(element.getAttribute('datetime'));
    if (isNaN(moment.getTime())) return;
    element.title = moment.toLocaleString();
    element.textContent = ago(moment);
  });

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
      status.textContent = 'Your phone is signed in (' + localTime(at) + ').';
    });
    window.addEventListener('pagehide', function () { stream.close(); });
  }

  window.addEventListener('pagehide', forgetCode);
})();
