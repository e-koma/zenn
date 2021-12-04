---
title: "使用頻度の低いGCEインスタンスを組織一括で検知する方法"
emoji: "🚿"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ['GCP', 'GCE', 'Terraform', 'Python']
published: true
---

:::message
この記事は [Akatsuki Advent Calendar 2021](https://adventar.org/calendars/6566) 兼 [Google Cloud Platform Advent Calendar 2021](https://qiita.com/advent-calendar/2021/gcp)
の5日目の記事です
:::

# 放置されたGCEインスタンスを検知したい

みなさま、年末の大掃除の時期になりましたね！
部屋はルンバが掃除してくれますが、悲しいことにサーバは掃除してくれません。

組織の中にGCPプロジェクトが増えてくると、統制/管理が大変になってきます。[^1]
特に放置されたGCEインスタンスが存在すると、コスト増にもつながりますし、思わぬセキュリティホールを抱え込むことにもなるため、使われていないサーバは管理者としてはすぐにでも消したい要望があります。

そんなときはCloud Asset Inventory + Recommenderを使うことで、組織を横断して使用頻度の低いGCEインスタンスを検知する仕組みを構築することができます。

[^1]: GCPプロジェクトは自分で作る以外にも、各種サービス (Firebase / Google Apps Script等)に紐付いて自動生成されたり、テスト実行時に新しいGCPプロジェクトを生成してその中でテストをするようなGoogle OSSも存在するため、気づけば大量のGCPプロジェクトが生成されていた、なんてことがあるかと思います。

## Recommenderとは

[Recommender](https://cloud.google.com/recommender/docs/overview)とはGCPリソースに関するアドバイスを提示してくれるサービスです。個人的にはこのUIは気づきづらいのですが、プロジェクトダッシュボードにも地味に表示されていたりします。

![](https://storage.googleapis.com/zenn-user-upload/cb9dbbfb8b5b-20211203.png =400x)

Recommenderにはさまざまな[種類](https://cloud.google.com/recommender/docs/recommenders)があり[^2]、この中の `Idle VM recommender` を使うことで、使用頻度の低いGCEインスタンスを検知することができます。

Recommender単体では1つのGCPプロジェクトの推奨事項しか見れないため、組織を横断して検知するには、GCPプロジェクト名一覧を取得して、プロジェクトごとに実行するような仕組みが必要になってきます。

しかし、RecommenderをCLI/SDKで利用する際には、GCPプロジェクト名に加え、GCEインスタンスを起動しているゾーン名の指定も要求されます。つまり事前に「組織の中で、どのGCPプロジェクトのどのゾーンでGCEインスタンスが起動しているか」を知っていなければなりません[^3]。

以下はRecommenderの使用例です。
```shell: Recommender利用例
GCP_PROJECT=<your gcp project id>

gcloud recommender recommendations list \
  --project="$GCP_PROJECT" \      # project以外に
  --location=asia-northeast1-b \  # locationも指定する必要がある
  --recommender=google.compute.instance.IdleResourceRecommender
```

[^2]: Recommenderの項目は定期的にupdateされて増えていってるのですが、GCPの [release notes](https://cloud.google.com/release-notes) にも記載されずにしれっと更新されているので、記載されてほしいところです^^;

[^3]: 無機質に全てのゾーンで検索する、という考え方もありますが、Firebase用に自動作成されたGCPプロジェクトのような、明らかにGCEインスタンスが必要のないGCPプロジェクトも組織の中には存在すると思われるため、かなり無駄が多い処理になると思われます。

## Cloud Asset Inventoryとは
そこで登場するのが[Cloud Asset Inventory](https://cloud.google.com/asset-inventory/docs/overview)です。
Cloud Asset Inventoryを使えば、組織全体のGCPリソースを一括検索することができます。GCEを起動しているゾーンも取得できるため、先程の課題であった「組織の中で、どのGCPプロジェクトのどのゾーンでGCEインスタンスが起動しているか」を1コマンドで知ることができます。

以下はCloud Asset Inventoryの使用例です。
```shell: Cloud Asset Inventory利用例
ORGANIZATION=<your organization id>

gcloud asset search-all-resources \
  --scope='organizations/****' \
  --asset-types=compute.googleapis.com/Instance
```

```shell: 実行結果
---
assetType: compute.googleapis.com/Instance
displayName: ****
location: asia-northeast1-b
name: //compute.googleapis.com/projects/****/zones/****/instances/****
state: RUNNING

# 〜略〜
```

# 使ってみる

ではCloud Asset InventoryとRecommenderを組み合わせて、使用頻度の低いGCEインスタンスを組織一括で検知してみたいと思います。

今回はCloud FunctionにデプロイしてSlackに通知する仕組みを作りました。
最初は記事の中にサンプルコードを貼ろうと思ったのですが、非常に長くなってしまうのと、どうせ貼るなら、使える形式の方が良いかと思って、Terraform Moduleとして公開しました。

https://github.com/e-koma/terraform-google-recommenders

なお、Terraform実行者には組織管理者の権限が必要になります。

# Terraform Moduleの使い方
ご自身のTerraform内に以下のように書いて`terraform init`すれば使うことができます。`terraform apply` でデプロイすると、Cloud Scheduler + Cloud Pub/Sub + Cloud Functionが作られます。デフォルトだと月に1回スキャンする設定になっていますが、パラメータでスキャン頻度を変えることもできます。

```hcl
module "recommenders" {
  source  = "e-koma/recommenders/google"
  version = "0.0.2"

  organization_id   = "****"
  gcp_project       = "****"
  bucket_name       = "****" # GCS bucket to manage Cloud Function codes
  slack_webhook_url = "****" # Slack Webhook URL to notify results
}
```

# 実行結果
Cloud SchedulerからRUN NOW (日本語UIだと今すぐ実行) で動作確認することができます。
実際に実行してみると、以下ように、組織内の全GCPプロジェクトの使用頻度の低いGCEインスタンスをSlack通知することができました。

![](https://storage.googleapis.com/zenn-user-upload/a4f61d6334bb-20211203.png =600x)

# まとめ
利用頻度の低いGCEインスタンスを組織一括で検知する仕組みを紹介しました。GitHubリポジトリ内では使用頻度の低いCloud SQLを検知するRecommenderもサポートしていたりします（設定を有効にすれば使えます）。クラウド管理は大変なのでいろんな仕組みを使って楽したいですね。

Happy GCP Management !!
