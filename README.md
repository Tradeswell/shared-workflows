# shared-workflows
---

Current workflows:

* Serverless node deploy

# How to use it
---

#### Serverless node deploy

* Make sure that serverless is installed as NPM dependency 
* NPM script contains following scripts in `package.json` - `deploy:{STAGE}`,  example:
```yaml
  "scripts": {
    "deploy:dev": "serverless deploy -s dev",
    "deploy:qa": "serverless deploy -s qa",
    "deploy:prod": "serverless deploy -s prod"
  }
```
* Add `aws.yml` workflow in `.github/workflows/` dir, example:

```yaml
name: CD/CI
on:
  push:
    branches: [ main ]
    paths-ignore:
      - '**/README.md'
      - '.gitignore'
      - 'docs/**'

  pull_request:
    branches: [ main ]
    paths-ignore:
      - '**/README.md'
      - '.gitignore'
      - 'docs/**'

  release:
    types:
      - published

jobs:
  deploy-qa:
    # Only deploy off the main branch
    if: github.ref == 'refs/heads/main'
    uses: Tradeswell/shared-workflows/.github/workflows/serverless_node_deploy.yml@main
    with:
      stage: 'qa'
    secrets:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      AWS_REGION: ${{ secrets.AWS_REGION }}
      SLACK_BOT_TOKEN: ${{ secrets.SLACK_BOT_TOKEN }}

  deploy-prod:
    # Only deploy for releases
    if: ${{ github.event_name == 'release' }}
    uses: Tradeswell/shared-workflows/.github/workflows/serverless_node_deploy.yml@main
    with:
      stage: 'prod'
    secrets:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      AWS_REGION: ${{ secrets.AWS_REGION }}
      SLACK_BOT_TOKEN: ${{ secrets.SLACK_BOT_TOKEN }}
```
