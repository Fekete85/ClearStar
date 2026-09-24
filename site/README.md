# ClearStar landing page

The site at https://clearstar.blackit.hu/ (Hungarian) and https://clearstar.blackit.hu/en/ (English).
A single-page Hugo site, built into its own nginx image.

| Path | What |
|---|---|
| `i18n/hu.yaml`, `i18n/en.yaml` | all text – edit these to change the wording |
| `layouts/home.html` | the one template; the 16 steps follow the app's sidebar |
| `static/style.css` | colours from `src/ClearStar.App/Themes/Dark.xaml` |
| `static/img/` | hero, social preview, screenshots per language (`<name>-hu.webp`, `<name>-en.webp`) |
| `hugo.toml` | languages and the outbound links (Store, GitHub, privacy, support) |

The server's Content-Security-Policy allows no inline scripts and no external fonts, so there are none.

## Build and deploy

The `Dockerfile` downloads a pinned Hugo release, renders the site and copies the result into
`nginx:1.27-alpine`; the server needs no Hugo of its own.

```
tar cf - -C site . | ssh $DEPLOY_HOST 'tar xf - -C ~/clearstar-site'
ssh $DEPLOY_HOST 'cd ~/clearstar-site && docker compose up -d --build'
```

Local preview with Hugo installed: `hugo server` in this folder.
