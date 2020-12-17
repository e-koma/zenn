# Zenn

## 使い方
- [CLI](https://zenn.dev/zenn/articles/zenn-cli-guide) /  [画像upload先](https://zenn.dev/dashboard/uploader)

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

gcloud run deploy zenn-preview \
  --image "gcr.io/$GCLOUD_PROJECT/zenn-preview" \
  --port 8000 \
  --platform managed \
  --allow-unauthenticated \
  --region asia-northeast1
```

## 限定公開削除
```
gcloud run services delete zenn-preview \
  --platform managed \
  --region asia-northeast1
```
