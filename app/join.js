// This script runs on the join page, /join. The invite's code is after the
// link's `#`, which no browser sends, so it reaches no server's log. The
// script puts the code in the form's hidden `code` field, asks the server
// for the name the invite holds (POST /join/name), and fills it in for the
// invitee to keep or change. The form then posts itself to /join.
(function () {
  "use strict";
  const form = document.querySelector("form[action='/join']");
  const said = document.createElement("p");
  form.before(said);
  const refused = (text) => {
    said.textContent = text;
    form.hidden = true;
  };
  const code = location.hash.slice(1);
  if (code === "") {
    refused("This link holds no invite code.");
    return;
  }
  form.elements.code.value = code;
  fetch("/join/name", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: "code=" + encodeURIComponent(code),
  }).then(async (answer) => {
    if (answer.ok) {
      form.elements.name.value = (await answer.json()).name;
    } else if (answer.status === 401) {
      refused("This invite has been used, or has expired. Ask the person who invited you for a new one.");
    } else {
      refused(await answer.text());
    }
  }, () => refused("The chat could not be reached. Reload the page to try again."));
})();
