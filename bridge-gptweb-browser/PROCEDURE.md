# GPTWeb browser connection

This is the browser-only GPTWeb procedure. It uses the GPTWeb browser handler
distributed by the CogentSpec marketplace. Do not execute a Windows launcher
from the AI session or substitute a Snap, Desk, Claude or Qwen connector.

Once per Windows user, the authorized CogentSpec marketplace setup runs this
directory's `install.ps1`. It verifies its fixed source inventory, installs a
background protocol handler and registers `cogentspec-gptweb`. It has no app
window, does not start a worker, replace credentials or approve a device. This
one-time Windows setup cannot be performed by browser permission alone. Never
claim it installed merely because these instructions were read.

`install-from-marketplace.ps1 -Revision <published commit> -InventorySha256
<published inventory hash>` fetches this artifact directly from the official
marketplace, verifies every downloaded file, then runs `install.ps1`. This is
the one-time Windows setup, using the existing approved CogentSpec installation;
it does not install a ChatGPT plugin, browser extension or separate app window.

For the normal `$gptweb` command:

1. Request the host's actual browser permission if necessary, and wait for it.
2. Claim only the intended existing `cogentspec.app/stack` tab whose URL has
   `experience=web` and `surface=chatgpt`. Preserve its drafts and layout. Do not
   open, navigate, reload or rearrange any tab or window.
3. Click the red Bridge light, the button named **Connect GPTWeb**. The existing
   page creates an account-bound, expiring startup request. Its installed GPTWeb
   handler verifies the account/device and starts its own background worker.
   Chrome owns any real first-use permission to run that handler. Never invent
   an AI permission question or approve an ownership/device transfer.
4. Wait for the page's fresh acknowledgement and visible **Bridge connected**
   status. Check that **My projects** is authorized without selecting a project.
   A running helper, startup response or browser permission is insufficient.
5. Report connected only after these checks. If the handler is missing or the
   account, ownership or connection check fails, report the exact visible
   message. Do not run an installer or ask for a Windows terminal in the AI.

The `$gptweb` copy button only copies this command and its marketplace procedure.
There is no Initiate Bridge step or routine connection-confirmation dialog.
