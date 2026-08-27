# Website deployment

The marketing and documentation site is deployed to Vercel from this monorepo.
The repository configuration in [`vercel.json`](../vercel.json) is the source
of truth for framework detection, dependency installation, build command, local
development command, and output location.

## Production contract

- **Production branch:** `main`.
- **Production URL:** <https://headless-web-pi.vercel.app>.
- **Project root:** the repository root, not `apps/web`.
- **Application:** `apps/web` (`@headless/web`).
- **Security headers:** `apps/web/next.config.ts`. Do not duplicate them in
  `vercel.json`, where they could drift from local and CI builds.

The Vercel project alias is the canonical domain for now. The LockInTime
organization does not publish a verifiable custom domain in repository or
organization metadata, so this project must not claim one. A custom domain can
replace the alias only after a maintainer confirms control of its DNS. That
change must update `apps/web/lib/site-metadata.ts`, the GitHub repository
homepage, this document, and the Vercel production-domain assignment together.

## GitHub integration

Connect the `LockInTime/headless` repository through Vercel for GitHub with
these project settings:

1. Leave Root Directory empty so Vercel reads the root `vercel.json` and the
   workspace lockfile.
2. Set the production branch to `main`.
3. Keep preview deployments enabled for pull requests and branch pushes.
4. Keep pull-request comments enabled so each PR receives its immutable preview
   URL. Keep deployment status events enabled so the URL also appears in the
   GitHub deployment timeline.
5. Do not add a second token-driven GitHub Actions deployment. Two independent
   deployers can race production aliases and make rollback history ambiguous.

The integration is an account-level control and cannot be stored in git. If a
PR has no Vercel deployment or preview link, treat that as a disconnected or
disabled integration. A Vercel project maintainer must reconnect the repository
under Project Settings, Git before the PR is considered deployment-verified.

## Verification

Run the same web gates locally before pushing:

```sh
pnpm install --frozen-lockfile --filter @headless/web
pnpm --filter @headless/web lint
pnpm --filter @headless/web build
```

For a pull request, open the Vercel preview from the PR deployment entry and
check the homepage, one docs route, `robots.txt`, and `sitemap.xml`. Confirm the
response still carries the CSP, `X-Content-Type-Options`, `X-Frame-Options`,
`Referrer-Policy`, and `Permissions-Policy` headers declared in
`apps/web/next.config.ts`.

After merging, verify that the production deployment points at the merge commit
and that <https://headless-web-pi.vercel.app> serves it. Vercel keeps prior
production deployments available for rollback. Roll back in Vercel, then
revert the faulty commit in git so repository history and production converge.
