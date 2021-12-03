---
title: "使用頻度の低いGCEインスタンスを組織横断で検知する方法"
emoji: "🚿"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ['gcp', 'recommender', 'python', 'terraform']
published: false
chapters:
  - 放置されたGCEインスタンスを検知したい
  - 使用頻度が低いGCEを検知する仕組みを公開しました
  - 使い方
  - 中身の話
  - 使ってみた結果
---

:::message
この記事は [Akatsuki Advent Calendar 2021](https://adventar.org/calendars/6566) 兼 [Google Cloud Platform Advent Calendar 2021](https://qiita.com/advent-calendar/2021/gcp)
の5日目の記事です
:::

# 放置されたGCEインスタンスを検知したい

みなさま、年末の大掃除の時期になりましたね！
部屋はルンバが掃除してくれますが、悲しいことにサーバは掃除してくれません。

組織の中にGCPプロジェクトが増えてくると、統制/管理が大変になってきます。[^1]
特に放置されたGCEインスタンスが存在すると、コスト増にもつながりますし、思わぬセキュリティホールを抱え込むことにもなるため、使われていないサーバは管理者としてはすぐにでも消したい要望があると思います。[^2]

そんなときはCloud Asset Inventory + Recommenderを使うことで、組織を横断して使用頻度の低いGCEインスタンスを検知する仕組みを構築することができます。


[^1]: GCPプロジェクトは自分で作る以外にも、各種サービス (Firebase / Google Apps Script等)に紐付いて自動生成されたり、テスト実行時に新しいGCPプロジェクトを生成してその中でテストをするようなGoogle OSSも存在するため、気づけば大量のGCPプロジェクトが生成されていた、なんてことがあるかと思います。

[^2]: 放置されたGCPプロジェクト自体を検知する方法なんかもあるのですが、今回は放置されたGCEインスタンスを検知する方法を紹介します。


## Recommenderとは

[Recommender](https://cloud.google.com/recommender/docs/overview)とはGCPリソースに関するアドバイスをしてくれるサービスです。気づきづらいのですが、プロジェクトダッシュボードにも地味に表示されていたりします。

![](https://storage.googleapis.com/zenn-user-upload/cb9dbbfb8b5b-20211203.png =400x)

Recommenderにはさまざまな[種類](https://cloud.google.com/recommender/docs/recommenders)があり[^3]、この中の `Idle VM recommender` を使うことで使用頻度の低いGCEインスタンスを検知することができます。一方でRecommender単体では1つのGCPプロジェクトの推奨事項しか見れないため、組織を横断して検知するには別の仕組みと組み合わせる必要があります。

組織を横断して使うためには、`gcloud projects list` でプロジェクト名一覧を取得すれば良さそうに思えるのですが、これではうまくいきません。理由はRecommenderをCLI/SDKで利用する際には、GCEインスタンスを起動しているGCPプロジェクト名に加え、ゾーン名の指定が必要になるからです[^20]。

```shell: Recommender利用例
GCP_PROJECT=<your gcp project id>

gcloud recommender recommendations list \
  --project="$GCP_PROJECT" \      # project以外に
  --location=asia-northeast1-b \  # locationも指定する必要がある
  --recommender=google.compute.instance.IdleResourceRecommender
```

つまり、事前に「組織の中でどのGCPプロジェクトのどのゾーンにGCEインスタンスが起動しているか」を知っていなければなりません。

[^3]: Recommenderの項目は定期的にupdateされて増えていってるのですが、GCPの [release notes](https://cloud.google.com/release-notes) にも記載されずにしれっと更新されているので、記載されてほしいところです^^;

[^20]: 無機質に全てのゾーンで検索する、という考え方もありますが、Firebase用に自動作成されたGCPプロジェクトのような、明らかにGCEインスタンスが必要のないGCPプロジェクトも組織の中には存在すると思われるため、かなり無駄が多い処理になると思われます。

## Cloud Asset Inventoryとは
そこで登場するのが[Cloud Asset Inventory](https://cloud.google.com/asset-inventory/docs/overview)です。
Cloud Asset Inventoryを使えば、組織全体のGCPリソースを一括検索することができます。
GCEを起動しているゾーンも取得できるため、先程の課題であった「組織の中でどのGCPプロジェクトのどのゾーンにGCEインスタンスが起動しているか」を知ることができます。


Cloud Asset Inventoryの実行例は以下のようになります。
```shell: Cloud Asset Inventory利用例
ORGANIZATION=<your organization id>

gcloud asset list \
  --organization="$ORGANIZATION" \
  --asset-types=compute.googleapis.com/Instance
```
```shell: 実行結果
---
ancestors:
- projects/****
- folders/****
- folders/****
- organizations/****
assetType: compute.googleapis.com/Instance
name: //compute.googleapis.com/projects/<gcp_project_id>/zones/<zone>/instances/<instance_name>
updateTime: '2021-11-24T02:50:52.839294Z'
---
# 〜続く〜
```

※ 停止中のGCEインスタンスは検知してくれません。


# 使ってみる

このCloud Asset Inventoryの検索結果を使ってRecommenderを利用すれば、組織を横断してRecommenderの内容を取得することができます。

今回はCloud Functionにデプロイして使ってみます。記事の中にサンプルコードを貼ろうと思ったのですが、どうせ貼るなら、使える形式の方が良いかと思って公開しました。

<!-- #使用頻度が低いGCEを検知する仕組みを公開しました -->

https://github.com/e-koma/terraform-google-recommenders


<!-- 仕組みとしてはCloud Asset Inventory + RecommenderをCloud Functionで実行しているだけなのですが、 -->

Cloud Function実行に必要な権限をいちいち調べるのが面倒だと思うので、Terraform Moduleとして使えるようにしています。（ただし、Terraform内で組織IAMに権限付与をする処理があるため、Terraform実行者には組織管理者の権限が必要になります...）


# サンプルコードの使い方
ご自身のTerraform内に以下のように書けばデプロイすることができます。デフォルトだと月に1回スキャンする設定になっていますが、パラメータでスキャン頻度を変えることができます。

```hcl
module "recommenders" {
  source  = "e-koma/recommenders/google"
  version = "0.0.1"

  organization_id   = "****"
  gcp_project       = "****"
  bucket_name       = "****" # GCS bucket to manage Cloud Function codes
  slack_webhook_url = "****" # Slack Webhook URL to notify results
}
```

# 実行結果
以下のようにSlackに通知することができます

![](https://storage.googleapis.com/zenn-user-upload/a4f61d6334bb-20211203.png =600x)


# まとめ
Cloud Asset Inventory + Recommenderで組織を横断して利用頻度の低いGCEインスタンスを検知する仕組みを紹介しました。需要があれば他のRecommenderも追加していこうかと思います。

Happy GCP Management !!
