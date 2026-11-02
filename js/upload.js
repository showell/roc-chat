/* upload.js: an image into the compose box, the old client's (chat-client's
   js/chat_compose.js `uploadFile`, `shrinkPicture`, `sendFile`), split out
   of compose.js, which hands it `Compose.insertAtCursor`. The server keeps
   the image in the topic's folder and answers its URL (app/Uploads.roc):
     - the Upload button picks a file; an image pasted into the box is sent
       the same way (anything else pasted is the box's);
     - a photo is shrunk in the browser first (Steve, 2026-10-12): its
       longest side at most 2048 px, a JPEG over 1.5 MB re-encoded at 0.85,
       a PNG scaled and kept PNG, a GIF or WebP sent as it is (either may
       move, and a canvas keeps one frame); the original goes when the
       shrunk one is no smaller, or anything about shrinking fails or takes
       past 15 s: a resize can make an upload smaller, never stop it;
     - patient and visible: one upload at a time, the button off while it
       runs; its progress said by percent and megabytes, then "Saving";
       given up only after 5 minutes. XMLHttpRequest, not fetch: fetch
       cannot say how much of a body has gone;
     - an image past the page's limit is said before it is sent; a refusal
       says the server's words; the answer puts `<img src alt>` at the
       cursor (no width or height: the server sends 0 for both). */
(function () {
  'use strict';
  var form = document.getElementById('chat-form');
  var text = document.getElementById('chat-body');
  var status = document.getElementById('chat-status');
  var button = document.getElementById('chat-upload-btn');
  var picker = document.getElementById('chat-file');
  var imageMost = Number(form.dataset.imageMost);
  var muted = 'var(--cc-muted-fg, #888)';

  var patienceMs = 5 * 60 * 1000;
  var photoLongestPx = 2048;
  var photoReencodeOverBytes = 1.5 * 1048576;
  var photoJpegQuality = 0.85;
  var photoPrepareMs = 15000;
  var jpegTypes = { 'image/jpeg': 1, 'image/jpg': 1, 'image/pjpeg': 1 };
  var uploading = false;

  function megabytes(n) { return (n / 1048576).toFixed(1) + ' MB'; }

  /* The resize a picture gets: null to send it as it is, else the size and
     type to draw it at. */
  function resizePlan(type, bytes, width, height) {
    var jpeg = jpegTypes[type] === 1;
    if (!(jpeg || type === 'image/png') || !(width > 0 && height > 0)) return null;
    var longest = Math.max(width, height);
    var scale = longest > photoLongestPx ? photoLongestPx / longest : 1;
    if (scale === 1 && !(jpeg && bytes > photoReencodeOverBytes)) return null;
    return {
      width: Math.max(1, Math.round(width * scale)),
      height: Math.max(1, Math.round(height * scale)),
      type: jpeg ? 'image/jpeg' : 'image/png',
    };
  }

  /* Hands `then` the file to send, exactly once: the shrunk one, or the
     original. The decode is an <img>'s, which every current browser turns
     upright by the photo's EXIF orientation. */
  function shrinkPicture(file, then) {
    var handed = false, url = null;
    function hand(f) {
      if (handed) return;
      handed = true;
      clearTimeout(watchdog);
      if (url) URL.revokeObjectURL(url);
      then(f);
    }
    var watchdog = setTimeout(function () { hand(file); }, photoPrepareMs);
    if (!(jpegTypes[file.type] === 1 || file.type === 'image/png')) return hand(file);
    try {
      url = URL.createObjectURL(file);
      var img = new Image();
      img.onerror = function () { hand(file); };
      img.onload = function () {
        try {
          var plan = resizePlan(file.type, file.size, img.naturalWidth, img.naturalHeight);
          if (!plan) return hand(file);
          var canvas = document.createElement('canvas');
          canvas.width = plan.width;
          canvas.height = plan.height;
          var g = canvas.getContext('2d');
          if (!g) return hand(file);
          if (plan.type === 'image/jpeg') { g.fillStyle = '#fff'; g.fillRect(0, 0, plan.width, plan.height); }
          g.imageSmoothingQuality = 'high';
          g.drawImage(img, 0, 0, plan.width, plan.height);
          canvas.toBlob(function (blob) {
            try {
              canvas.width = canvas.height = 0;
              if (!blob || blob.size >= file.size) return hand(file);
              var name = (file.name || 'image').replace(/\.[^.]*$/, '') + (plan.type === 'image/jpeg' ? '.jpg' : '.png');
              hand(new File([blob], name, { type: plan.type }));
            } catch (e) { hand(file); }
          }, plan.type, photoJpegQuality);
        } catch (e) { hand(file); }
      };
      img.src = url;
    } catch (e) { hand(file); }
  }

  function done(line) {
    uploading = false;
    button.disabled = false;
    status.style.color = '';
    status.textContent = line;
  }

  function sendFile(file) {
    if (file.size > imageMost) {
      return done('That image is ' + megabytes(file.size) + ' — too big to send (limit ' + (imageMost / 1048576) + ' MB). Try compressing or resizing it.');
    }
    status.style.color = muted;
    status.textContent = 'Uploading image: 0% of ' + megabytes(file.size) + '…';
    var fd = new FormData();
    fd.append('file', file);
    var xhr = new XMLHttpRequest();
    xhr.open('POST', form.dataset.upload);
    xhr.timeout = patienceMs;
    xhr.upload.onprogress = function (e) {
      if (!e.lengthComputable) return;
      var pct = Math.floor(100 * e.loaded / e.total);
      status.textContent = pct < 100 ? 'Uploading image: ' + pct + '% of ' + megabytes(e.total) + '…' : 'Saving image…';
    };
    xhr.onload = function () {
      if (xhr.status < 200 || xhr.status >= 300) {
        var t = (xhr.responseText || '').trim();
        return done((t && t.charAt(0) !== '<' && t.length < 200) ? t : 'Upload failed.');
      }
      var d;
      try { d = JSON.parse(xhr.responseText); } catch (e) { return done('Upload failed: the answer did not read (' + e.message + ').'); }
      var alt = (d.name || 'image').replace(/["<>\r\n]/g, '');
      var dims = (d.width > 0 && d.height > 0) ? ' width="' + d.width + '" height="' + d.height + '"' : '';
      Compose.insertAtCursor('<img src="' + d.url + '" alt="' + alt + '"' + dims + '>');
      done('');
    };
    xhr.onerror = function () { done('Upload failed: the connection dropped. Please try again.'); };
    xhr.ontimeout = function () { done('Upload gave up after ' + (patienceMs / 60000) + ' minutes. Please try again.'); };
    xhr.send(fd);
  }

  function uploadFile(file) {
    if (!file) return;
    if (uploading) {
      status.style.color = '';
      status.textContent = 'Still sending the last upload — one at a time, please.';
      return;
    }
    uploading = true;
    button.disabled = true;
    status.style.color = muted;
    status.textContent = 'Preparing image…';
    shrinkPicture(file, sendFile);
  }

  button.addEventListener('click', function () { picker.click(); });
  picker.addEventListener('change', function () { uploadFile(picker.files[0]); picker.value = ''; });
  text.addEventListener('paste', function (e) {
    var files = e.clipboardData && e.clipboardData.files;
    if (files) for (var i = 0; i < files.length; i++) {
      if (files[i].type.indexOf('image/') === 0) { e.preventDefault(); uploadFile(files[i]); return; }
    }
  });
  window.Upload = { resizePlan: resizePlan };
})();
