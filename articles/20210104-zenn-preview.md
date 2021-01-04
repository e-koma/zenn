---
title: "Zennの記事を限定公開する方法"
emoji: "🔖"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ['zenn', 'gcp', 'cloudrun']
published: true
---

# Zennは限定公開機能がない
いきなりですが、Zennは限定公開機能がありません（たぶん）。 個人ブログを書く分には良いのですが、仕事の内容を記事にするときは事前にレビューが必要なこともあり、Zennでは書きづらいと思います。

今回はZennで限定公開を実現し、第三者レビューを可能にする話を書きます。 幸いなことに、Zennはローカル開発用のサーバが用意されているので、これをサクっと公開してしまえばよいのです。

:::message
2021/01/04時点の話ですので、Zennに限定公開機能がリリースされればこの記事は不要になります
:::

# 事前準備

#### 1. 記事を書く
[Zenn CLI](https://zenn.dev/zenn/articles/zenn-cli-guide) を使って記事を書きましょう。 Zenn CLIをinstallして`npx zenn new:article` を実行すると、`articles`配下に記事の雛形ファイルができるので、このファイルに記事を書きます。

```
.
└─ articles
   └── example-article1.md
```


#### 2. Dockerfileを用意する
以下のDockerfileを用意します。 Zenn CLIのinstall手順およびpreviewをそのままDockerfile化しただけです。 Dockerfileは一度用意してしまえば、今後触れることはほとんどありません。

```dockerfile
FROM node:current-alpine3.12

WORKDIR /app
RUN apk add --no-cache --virtual .build-deps git \
    && npm init --yes \
    && npm install zenn-cli \
    && npx zenn init \
    && apk del .build-deps
COPY articles articles
COPY books books

ENTRYPOINT ["npx", "zenn", "preview"]
```

記事のリポジトリのrootにDockerfileを起きます
```
.
├─ articles
│  └── example-article1.md
└─ Dockerfile
```

# 限定公開
サクっと公開と言えば、GCPのCloud Runでしょう。 Cloud RunにデプロイしてURLを共有すれば、Web上で記事を書いたような形式でレビューが可能になります。以下のコマンドでCloud Runデプロイします。

```sh
GCLOUD_PROJECT=<your project>

gcloud config set project "$GCLOUD_PROJECT"
gcloud auth configure-docker

docker build -t "gcr.io/$GCLOUD_PROJECT/zenn-preview" .
docker push "gcr.io/$GCLOUD_PROJECT/zenn-preview"

service_name="zenn-preview-$(uuidgen | tr [:upper:] [:lower:])"
gcloud run deploy "$service_name" \
  --image "gcr.io/$GCLOUD_PROJECT/zenn-preview" \
  --port 8000 \
  --platform managed \
  --allow-unauthenticated \
  --region asia-northeast1
```

:::message
Cloud RunデプロイするとURLにもランダム文字列が付与されますが、念の為サービス名自体にもランダム文字列を付与しています
:::

デプロイが完了するとURLが生成されます。

![](https://storage.googleapis.com/zenn-user-upload/i45t0foww8q82zpjsrz22p0qtaph)

# 記事のレビュー

生成されたURLを限定公開用URLとして、レビューして欲しい人に共有すればOKです。
(正確には`https://<Cloud Run URL>/<記事slug名>`)
以下は今回の記事をCloud Runにデプロイした結果です。Webの形式で記事をレビューできるのが分かるかと思います。

![](https://storage.googleapis.com/zenn-user-upload/5qlvq5d5w1w4qsf1p3ji5fzv29le =600x)


# 限定公開削除
デプロイしたもろもろを消します
```sh
gcloud run services delete "$service_name" --platform managed --region asia-northeast1
gcloud container images delete "gcr.io/$GCLOUD_PROJECT/zenn-preview"
```

# 記事の公開
ZennとGitHub連携をして、 記事のオプションを `published: true` にしてgit pushしましょう

# まとめ
Zennには限定公開機能がありませんが、Cloud Runにデプロイすることで限定公開機能を実現する話を書きました。 Cloud Runはこういう用途には非常に便利ですね。 