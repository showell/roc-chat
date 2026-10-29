# Deploying roc-chat

roc-chat serves https://chat.lynrummy.com from the prod droplet
(162.243.1.123), behind the Caddy already there for lynrummy.com. The host
listens on 127.0.0.1:9490 alone; Caddy holds the certificate, logs every
request, and is the only way in.

| What | Where on prod | From |
|---|---|---|
| the binary (static, Debug) | `/opt/roc-chat/roc-chat`, root's, read-only to the service | built here by `tools/deploy.shale` |
| the service's folder | `/var/lib/roc-chat`, the `rocchat` user's, mode 700 | made by the deploy |
| the config | `/var/lib/roc-chat/config.zon` | `deploy/config.zon`, installed once |
| the data | `/var/lib/roc-chat/data` | the chat's own |
| the secrets | `/var/lib/roc-chat/data/secrets/` | Steve writes two; the server makes the signing key |
| the unit | `/etc/systemd/system/roc-chat.service` | `deploy/roc-chat.service` |
| the site block | `/etc/caddy/sites/chat.lynrummy.com.caddy` | `deploy/chat.lynrummy.com.caddy` |
| the access log | `/var/log/caddy/chat-access.log` | Caddy's |

## The first time (Steve)

1. **The DNS record:** an A record for `chat.lynrummy.com`, pointing at
   162.243.1.123. The deploy refuses until the public DNS says so.
2. **The GitHub OAuth app** (github.com → Settings → Developer settings →
   OAuth Apps → New): its homepage `https://chat.lynrummy.com`, and its
   callback URL **`https://chat.lynrummy.com/login/github`**.
3. **Its id and secret on prod**, each the `rocchat` user's alone. Run the
   deploy once first (it makes the user and the folders, then refuses here
   by name), then, for each of the two files, run the line and paste the
   value, then press Ctrl-D:

   ```
   ssh steve@162.243.1.123 'sudo install -o rocchat -g rocchat -m 600 /dev/stdin /var/lib/roc-chat/data/secrets/github-client-id'
   ssh steve@162.243.1.123 'sudo install -o rocchat -g rocchat -m 600 /dev/stdin /var/lib/roc-chat/data/secrets/github-client-secret'
   ```

   A trailing newline is dropped when the server reads them. The server
   refuses to start if either is missing, empty, a link, or readable by
   anyone else, and says which.

## Every deploy

```
shale tools/deploy.shale
```

It runs from roc-chat's root with no arguments. It refuses on a dirty
tree, pushes, builds, copies and proves the binary, restarts, installs
the site block when it changed (Caddy validates it first, and the old
one goes back if it fails), and ends by checking over HTTPS that `/`
answers and `/login` sends the browser to GitHub. Its header lists every
step and every refusal.

The deploy never overwrites the server's `config.zon`. A change to
`deploy/config.zon` after the first deploy is copied by hand.

## Backups

```
shale tools/backup.shale
```

It pulls `/var/lib/roc-chat/data` as one timestamped tar into
`~/build/roc-chat-backups` on this box. `secrets/` is left out: the OAuth
secret is GitHub's to issue again, and a new signing key only signs
everyone out.

## Pitfalls

- **Signing in needs HTTPS.** The session cookies are `__Host-` and
  `Secure`, so a test against the bare droplet over plain http serves
  pages but signs no one in (angry-gopher's Caddyfile says the same).
- **A stream goes through Caddy as it comes:** the site block sets
  `flush_interval -1`. Without it, SSE frames could sit in Caddy's buffer.
- **The access log is Caddy's before Caddy validates:** `caddy validate`
  runs as root and would make a missing log root's, and the reload would
  then fail. The deploy makes it first, as roc-apps' deploy does for
  roc.lynrummy.com.
