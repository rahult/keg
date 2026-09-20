import Foundation

/// The apps that ship inside Keg. Each entry is a catalog YAML document
/// (same format a user-added `~/.keg/apps/catalog/*.yaml` uses). Templates
/// follow two rules:
///  1. placeholders that are the whole YAML value are written bare — the
///     renderer quotes them as needed;
///  2. placeholders embedded in a longer value sit inside template quotes
///     and must therefore be plain text (no `"`/`\`/newlines — the
///     renderer refuses those).
///
/// Bundled apps are deliberately single-service. Apple container 1.3.1 has
/// no inter-container name resolution (runtime /etc/hosts is self-only, no
/// embedded DNS, no --add-host — verified live and in the vendored
/// RuntimeService.swift source), so multi-service templates (Miniflux,
/// WordPress, Paperless-ngx) cannot reference their databases by name and
/// are left out until the runtime resolves peers; re-add them then.
enum BundledAppCatalog {
    static let yamlContents: [String] = [
        memos, linkding, uptimeKuma, vaultwarden, gitea,
        umami, syncthing, nocodb, jellyfin,
    ]

    static let memos = """
    id: memos
    name: Memos
    tagline: Lightweight, self-hosted note taking
    category: Notes
    icon: note.text
    summary: |
      A privacy-first note-taking service — think of it as your own personal
      notes app that lives on this Mac. Write quick notes, tag them, and
      search everything from a clean web interface.
    note: The first account you create becomes the administrator.
    webUI:
      port: 5230
      path: /
    compose: |
      services:
        memos:
          image: neosmemo/memos:stable
          container_name: kegapp-memos-app
          ports:
            - "{{.KegWebPort}}:5230"
          environment:
            MEMOS_MODE: prod
            MEMOS_PORT: "5230"
          volumes:
            - {{.KegDataDir}}/data:/var/opt/memos
    """

    static let linkding = """
    id: linkding
    name: linkding
    tagline: Fast bookmark manager built for minimalists
    category: Bookmarks
    icon: bookmark.fill
    summary: |
      Save and organize your bookmarks in one place, on your own machine.
      linkding is fast, searchable, and has browser extensions for one-click
      saving.
    note: The admin account below is created automatically on first start.
    webUI:
      port: 9090
      path: /
    fields:
      - id: AdminUsername
        label: Admin username
        default: admin
      - id: AdminPassword
        label: Admin password
        type: password
        generate: true
    compose: |
      services:
        linkding:
          image: sissbruecker/linkding:latest
          container_name: kegapp-linkding-app
          ports:
            - "{{.KegWebPort}}:9090"
          environment:
            LD_SUPERUSER_NAME: {{.AdminUsername}}
            LD_SUPERUSER_PASSWORD: {{.AdminPassword}}
          volumes:
            - {{.KegDataDir}}/data:/etc/linkding/data
    """

    static let uptimeKuma = """
    id: uptime-kuma
    name: Uptime Kuma
    tagline: Monitor your websites and services
    category: Monitoring
    icon: waveform.path.ecg
    summary: |
      A self-hosted monitoring tool that checks whether your websites,
      servers, and services are up — and tells you when they are not. Set up
      checks in minutes with a friendly web interface.
    note: Create your admin account the first time you open it.
    webUI:
      port: 3001
      path: /
    compose: |
      services:
        uptime-kuma:
          image: louislam/uptime-kuma:1
          container_name: kegapp-uptime-kuma-app
          ports:
            - "{{.KegWebPort}}:3001"
          volumes:
            - {{.KegDataDir}}/data:/app/data
    """

    static let vaultwarden = """
    id: vaultwarden
    name: Vaultwarden
    tagline: Your own password manager, Bitwarden-compatible
    category: Security
    icon: key.fill
    summary: |
      A lightweight server that speaks the Bitwarden protocol, so you can use
      the official Bitwarden apps and browser extensions — with your data
      stored on this Mac instead of in the cloud.
    note: |
      Optional: leave the admin token empty to disable the admin panel, or
      set one to manage settings at the /admin page. Sync from the Bitwarden
      app by pointing it at http://127.0.0.1:<port>.
    webUI:
      port: 8222
      path: /
    fields:
      - id: AdminToken
        label: Admin panel token
        type: password
        required: false
        advanced: true
        generate: true
        help: Leave empty to disable the /admin panel (recommended).
    compose: |
      services:
        vaultwarden:
          image: vaultwarden/server:latest
          container_name: kegapp-vaultwarden-app
          ports:
            - "{{.KegWebPort}}:80"
          environment:
            ADMIN_TOKEN: {{.AdminToken}}
          volumes:
            - {{.KegDataDir}}/data:/data
    """

    static let gitea = """
    id: gitea
    name: Gitea
    tagline: Painless self-hosted Git service
    category: Development
    icon: chevron.left.forwardslash.chevron.right
    summary: |
      Your own GitHub-style home for code: repositories, issues, pull
      requests, and wikis, running entirely on this Mac. Works with the git
      command line and any Git client over HTTP.
    note: A setup wizard appears on first open — choose SQLite and the defaults.
    webUI:
      port: 3000
      path: /
    compose: |
      services:
        gitea:
          image: gitea/gitea:latest
          container_name: kegapp-gitea-app
          ports:
            - "{{.KegWebPort}}:3000"
          environment:
            USER_UID: "1000"
            USER_GID: "1000"
          volumes:
            - {{.KegDataDir}}/data:/data
    """


    static let umami = """
    id: umami
    name: Umami
    tagline: Privacy-focused web analytics
    category: Analytics
    icon: chart.bar.fill
    summary: |
      A simple, fast alternative to Google Analytics for your websites. Drop
      the tracking snippet into any site and watch visits roll in — with no
      cookies and no data leaving this Mac.
    note: Sign in with admin / umami and change the password right away.
    webUI:
      port: 8281
      path: /
    fields:
      - id: AppSecret
        label: App secret
        type: password
        generate: true
        advanced: true
        help: Random string used to sign session data.
    compose: |
      services:
        umami:
          image: ghcr.io/umami-software/umami:latest
          container_name: kegapp-umami-app
          ports:
            - "{{.KegWebPort}}:3000"
          environment:
            DATABASE_URL: "file:/data/umami.db"
            APP_SECRET: {{.AppSecret}}
            HOSTNAME: 0.0.0.0
          volumes:
            - {{.KegDataDir}}/data:/data
    """

    static let syncthing = """
    id: syncthing
    name: Syncthing
    tagline: Keep folders in sync across your devices
    category: Files
    icon: arrow.triangle.2.circlepath
    summary: |
      Sync folders between your Mac, phone, and other computers — directly,
      privately, and without any cloud in the middle. Pair devices once and
      Syncthing keeps them up to date.
    note: |
      After opening, add this Mac as a device in Settings → Show ID, then
      pair your other devices with it.
    webUI:
      port: 8384
      path: /
    compose: |
      services:
        syncthing:
          image: syncthing/syncthing:latest
          container_name: kegapp-syncthing-app
          ports:
            - "{{.KegWebPort}}:8384"
            - "22000:22000/tcp"
            - "22000:22000/udp"
            - "21027:21027/udp"
          environment:
            STGUIADDRESS: 0.0.0.0:8384
          volumes:
            - {{.KegDataDir}}/sync:/var/syncthing
    """

    static let nocodb = """
    id: nocodb
    name: NocoDB
    tagline: Databases that feel like spreadsheets
    category: Databases
    icon: tablecells
    summary: |
      Build little business apps and shared tables without writing code —
      an open alternative to Airtable that stores everything on this Mac.
      Invite others and work on rows together.
    webUI:
      port: 8282
      path: /
    compose: |
      services:
        nocodb:
          image: nocodb/nocodb:latest
          container_name: kegapp-nocodb-app
          ports:
            - "{{.KegWebPort}}:8080"
          volumes:
            - {{.KegDataDir}}/data:/usr/app/data
    """


    static let jellyfin = """
    id: jellyfin
    name: Jellyfin
    tagline: Your movies and music, streamed everywhere
    category: Media
    icon: play.tv.fill
    summary: |
      A media server that puts your movie, TV, and music library on every
      screen in the house — smart TVs, phones, and browsers — with no
      subscription and no cloud.
    note: |
      Choose the folder that holds your media below, then finish the setup
      wizard (library scan) on first open.
    webUI:
      port: 8096
      path: /
    fields:
      - id: MediaDirectory
        label: Media folder
        type: directory
        default: "{{.KegDataDir}}/media"
        help: The folder with your movies, shows, and music. Mounted read-only.
    compose: |
      services:
        jellyfin:
          image: jellyfin/jellyfin:latest
          container_name: kegapp-jellyfin-app
          ports:
            - "{{.KegWebPort}}:8096"
            - "1900:1900/udp"
            - "7359:7359/udp"
          environment:
            TZ: {{.KegTimeZone}}
          volumes:
            - {{.KegDataDir}}/config:/config
            - {{.KegDataDir}}/cache:/cache
            - {{.MediaDirectory}}:/media:ro
    """

}
