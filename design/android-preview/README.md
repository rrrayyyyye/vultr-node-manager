# Android interface prototype

Open `index.html` in a browser to review the proposed mobile screens. This is a visual and interaction prototype, not an Android APK. All values are synthetic; it makes no cloud API requests and does not read local credentials. The Vultr console link navigates to the real website only when explicitly clicked.

The three screens show the dashboard, node details, and destructive-action confirmation. The dashboard's Account tab opens the account view, where an "Open Vultr console" link sits below the balance card. This link opens `https://my.vultr.com/` in a separate browser tab without passing API credentials. Click the confirmation button to preview an accepted request followed by confirmed deletion; this is strictly a local animation.

The eventual Android app should preserve the existing region isolation, cloud-authoritative status checks, pending deletion state, account-balance calculation, and local-only private settings. Managing a node remains separate from connecting through FlClash.
