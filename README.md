# Zenn

## 使い方
- [CLI](https://zenn.dev/zenn/articles/zenn-cli-guide) /  [画像upload先](https://zenn.dev/dashboard/uploader)

## 初期セットアップ
Zennコンテンツを管理したいディレクトリ配下で
```
npm init --yes
npm install zenn-cli
```

## 記事作成
```
npx zenn new:article --slug "<slug名>" --type tech
```

## local preview
```
npx zenn preview
```

## 限定公開

```
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

## 限定公開削除
```
gcloud run services delete "$service_name" \
  --platform managed \
  --region asia-northeast1

gcloud container images delete "gcr.io/$GCLOUD_PROJECT/zenn-preview"
```
