# Zenn

## 使い方
- [CLI](https://zenn.dev/zenn/articles/zenn-cli-guide) /  [画像upload先](https://zenn.dev/dashboard/uploader)


## local 検証
```
docker build -t zenn-preview .
docker run -d -p 8000:8000 -t zenn-preview
# access to http://localhost:8000
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

## 公開削除
```
gcloud run services delete zenn-preview \
  --platform managed \
  --region asia-northeast1
```
