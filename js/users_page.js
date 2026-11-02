/* users_page.js: the users page's are-you-sure (app/UsersPage.roc): a
   Remove button asks first, naming who, and sends nothing unless the admin
   says yes. */
(function () {
  'use strict';
  document.addEventListener('submit', function (e) {
    var form = e.target;
    if (!form.classList || !form.classList.contains('erase')) return;
    if (!window.confirm('Remove ' + form.dataset.name + ' and everything of theirs? This cannot be undone.')) e.preventDefault();
  });
})();
