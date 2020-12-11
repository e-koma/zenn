---
title: "あと2時間でElastiCacheのメモリが枯渇！そのときあなたは何をしますか？"
emoji: "🔥"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["aws", "rds", "elasticache", "ec2", "ecs"]
published: false
---

:::message
この記事は [Akatsuki Advent Calendar 2020](https://adventar.org/calendars/5174) 兼 [AWS & Game Advent Calendar 2020](https://qiita.com/advent-calendar/2020/aws-game)
の18日目の記事です
:::

# 突然ですが...

あなたは、あるゲームプロジェクトの本番リリース2日前にサーバエンジニアとしてJOINしました。いざ、リリースを迎えたとき、ElastiCacheのメモリが突然危険域を超え、さらにあと2時間で枯渇しそうな状況になりました。

さて、この状況におかれたあなたは何をしますか？

| ![](https://storage.googleapis.com/zenn-user-upload/eqeiohxhcw6sjxueec2pkhpe6nu0)|
|:--|

# はじめに
モバイルゲームはリリース時にアクセスが一斉集中したり、何かイベントをopenするとアクセスが2倍3倍来ることもざらあります。
この記事は、あるゲームプロジェクトの本番リリース時に大規模アクセスが来た際のサーバトラブルを題材に、

- どのような観点で問題を切り分けていくのか、トラブルシュートのプロセス
- どのような準備(負荷テスト)をしていれば防げるのか

という話をしていきます。トラブルの内容としてはありがちなトラブルではあるので、普段からインフラを見ている方は、つらい気持ちになるのでそっ閉じするか「あー、はい、はい」ぐらいの感覚で見ていただけると幸いです。

# 記事の想定読者
- インフラの本番トラブルシュートをあまり経験したことがないサーバエンジニア

# 前提のストーリー
- あるゲームプロジェクトが本番リリース間際です。普段、リリース数ヶ月前には、インフラ部隊がJOINして非機能要件を整えることが多いのですが、今回はある特殊な事情でインフラ部隊は発動せず、リリース直前2日前に、監視要因として私がJOINすることになりました。かつ、チームメンバーも知らない人たちばかりです。

![](https://storage.googleapis.com/zenn-user-upload/5jyfk4hnlx8p9o5zxf1ees2x2edr =400x)

- つまり、チームメンバーとの信頼関係がそこまで築けていない状態かつ、システム全体の思想や中身をあまり知らない中、突然本番監視をすることになります。私に与えられた権限はAWS/Datadog GUIが見れる、EC2ログインができる、といった権限です。

# 本題に入る前に
- この記事は本番トラブルを晒すという特性上、事前準備が不足しているなと感じる場面が多々あるかもしれません。が、プロモーション/スケジュールの関係上、工数が足りない状況は多々あると思いますし、前提情報が不足している中「事前準備足りないだけじゃん」というコメントはご遠慮ください。「生のグラフ」というのはリアリティがあり価値があるものですし、知識のシェアのためにトラブル内容や生グラフを晒しているので、優しい世界を作るようお願いします。
- 問題切り分けは私の方でやりつつも、リカバリオペレーションを極力相手に任せるようなコミュニケーションを取っているので、人によってはグラフがややスピード感に欠けたトラブルシュート時間軸になっていると感じるかもしれませんが、それも目をつぶってください。

# アーキテクチャ
- アプリケーションがECSで運用されており、データストアがAurora MySQL + ElastiCache(Redis)、加えてログ基盤があり、シンプルなステートレスアーキテクチャです。(アセット配信等は省略)

![](https://storage.googleapis.com/zenn-user-upload/3nb4dhm4g3y23b0rwx5n32rn73sh =400x)

# リリース時に発生した問題
## RDS編
![](https://storage.googleapis.com/zenn-user-upload/4i42qgg7xzeyjuryrvuu913vxhf1 =80x)

## 発生した問題その1: CPUUtilization爆増問題

### 検知契機
- 監視の基本は外形監視なので、まずは外形監視の話からしていきます。
- 監視をしていると、ALBレスポンスタイムのp99が安定しない状況が見受けられました。（青: p99、紫：p95、黄、p50） このとき、EC2(vCPU16)のCPU使用率(max)に対するLoad Averageが妙に高く、バックエンドの何かで詰まっていると思われるようなグラフが観測されました。

![](https://storage.googleapis.com/zenn-user-upload/ykutmusz4d6g9ulym97tn9zn0ig6 =400x)
![](https://storage.googleapis.com/zenn-user-upload/6mcc5ep3uhc4mwtnfrl3oun0g5ev =400x)
![](https://storage.googleapis.com/zenn-user-upload/bu0kkynsjykh031yo6ulobkz2re4 =400x)

- まず目についたのはRDSのCPUUtilizationです。ややLatencyが低下していることも観測され、RDSのCPUUtilizationが頭打ちという状態です。なかなかにイケてる(不謹慎)グラフが取れているかと思います。

![](https://storage.googleapis.com/zenn-user-upload/nl61uz4m5oytyl4nzrsh9rhi22ym =400x)

### 初動
- この場ではRDSのクラスを変更して対応しました。RDSのクラス変更は時間がかかるため、いきなりWriterを変更はしません。AuroraのFailoverは高速で、1分程度で完了するため(ドキュメント上は [30秒](https://aws.amazon.com/jp/rds/aurora/faqs/) と言ってますね )、Reader側のクラス変更をしてFailoverをするというのが常套手段です。(Failover時にタイミング悪く古いDNS参照するサーバもいるので、その後、コンテナ再起動するのが無難）

![](https://storage.googleapis.com/zenn-user-upload/gqyb10ayled570q93i2f0lwz7gqq =400x)

### 原因調査
- スケールアップをしつつも、何が負荷をかけているのかを調査しました。よく見る事例としては、アプリケーション内でN+1クエリを発行するような実装があり、DBに負荷をかけているといったことがありますが、今回は見受けられませんでした。
    - このような状況下では、従来のMySQLでは Slowクエリを見たり、 `show processlist` `show variables` `show status` `show engine innodb status` のようなコマンドを実行し、中身を調査する、またはこれらの統計情報を定期的に取得しておき、監視サービスで分析する、といったアプローチがよくあったかと思います。 
    - が、ここはAurora。 [Performance Insights](https://docs.aws.amazon.com/ja_jp/AmazonRDS/latest/UserGuide/USER_PerfInsights.html) が力を発揮します。Performance Insightsはなかなかの神ツールなので、本番運用しているAuroraはぜひとも有効化しておきたいところです。
- Performance Insights(下記画像)を見ると、redo logのIO待ちが高いことが分かります。が、これは負荷が高いからこそ結果的に起きうるので、一概にこれが原因とは言えません。
- 他にも妙にmutex負荷が目立つのも分かります。

![](https://storage.googleapis.com/zenn-user-upload/4z2ceeb3274cx5ese7s03qcf2ryu)

- 上記に加えて、他にもLockが影響していそうなメトリクスが複数観測されため、Lock負荷が悪さしているだろうという仮説が観点として挙がりました。つまり、ロックの取り方、ロック範囲を見直すのが王道ではありそうです。
    - （他の観点としては、トランザクション分離レベルをRepeatable-ReadからRead-Commitedに変更するという発想があります。モバイルゲームシステムの特性上、共有データを同時に書き換えるような処理はほぼないだろうと思われるので考えつく発想ですが、もちろん本番でいきなり変更するのはリスクがありまくるので、影響範囲調査 & 開発環境でしっかり検証は必要になりますが、これをするとめちゃくちゃロック負荷が下がります。）
- トランザクション分離レベルの話なんかを出しましたが、いきなり変えることはリスクがあるのでさすがに見送り、今後の課題へ。またロックの貼り方も全体的にチェックしてもらうことになりました。

## 発生した問題その2: RDSコネクション増えすぎ問題

### 検知契機
- 監視してたところ、突然DB connectionが爆増したことに気づきました。AuroraはDB connectionが [16000](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraMySQL.Managing.Performance.html#AuroraMySQL.Managing.MaxConnections) で上限。あるタイミングでは一瞬完全に上限に達して、これ以上のコネクション生成はエラーが出るようになりました。

![](https://storage.googleapis.com/zenn-user-upload/g75fyynqy2qhl04jij47p42cm9n2 =400x)

### 初動
- 初動としては残念ながらRDS再起動で乗りきるしかなく、再起動で対応しました。

### 調査内容
- DB connection poolの設定を調査
    - 調べたところ、 `MaxPoolSize=800;` になっていました。コンテナは256個動いていたので、最大 `256 * 800 = 204800` まで許可する設定になっているということです。
    - どう考えても多すぎなので、 `12000 (バッファ込みの上限) / 256 (コンテナ数) = 46.875` で、30〜40 poolぐらいで運用してはどうかと提案しました。（スケールアウトできない前提の数字になっているが目をつぶってください）
- あと、ついでにECSデプロイオプションを見直しました。
    - ECSのデプロイ戦略が、デプロイ最大ヘルス率200、最小ヘルス率100の運用になっており、最大ヘルスが200になった際にコネクションを余計に掴んでしまうような状況になっていました。このconnectionギリギリの状況下ではデプロイ戦略が悪さをすることになるので、収束しないうちは、最大ヘルス率100、最小ヘルス率80ぐらいで運用してはいかが？と提案し、デプロイ時にコネクションが爆増しないように運用調整もしました。

## おまけ
- connectionが上限まで増えるということは、MySQLの [table_open_cache](https://dev.mysql.com/doc/refman/5.6/ja/table-cache.html) の使用量が気になるところですが、チェックしたところ、設定的にも使用量的にも問題はなさそうでした。

```
# 設定値
table_open_cache  6000
# 使用状況
Open_tables  2509
```
- このあたりはAuroraのデフォルトパラメータ `LEAST({DBInstanceClassMemory/1179121}, 6000)` が頑張ってくれているという所感です。

:::message
RDSはファイルディスクリプタ上限である `open_files_limit` を増やすことができません。つまり、 `max_connections` と `table_open_cache` をバランス良く設計しなければならないのですが、利用者がこれをあまり考えなくていいように、 `max_connections` に16000という上限が設けられていると解釈しています
:::

## ElastiCache編 ![](https://storage.googleapis.com/zenn-user-upload/abr8p50oguwuk5xvsqqpnzkf96vk =80x)

## 発生した問題その1: CPUUtilization爆増問題

### 検知契機
- RDSと同じく、レイテンシ遅延 -> バックエンド負荷高そう、という流れで検知しました。

### 調査内容
- 目についたのはElastiCacheのCPUUtilizationです。
- ElastiCache（Redis)はcache.m5.xlarge(vCPU 4コア)で運用されていました。Redisはシングルスレッドで動作しマルチコアスケールしないかつ、わずかながらLatencyが低下していることも観測されたため、以下のCPUUtilizationは限界と言えるでしょう。

![](https://storage.googleapis.com/zenn-user-upload/04q2tpug5k5e39i086w0vq115utu)

### 対応
- まずはどの処理に負荷がかかっているのか/キーの中身などを調査したいところではありますが、その話は後ほど出てきます。
- Redisはゲームのマスタデータをキャッシュしており、全Readerノードに同じデータが格納されている & 消えても別のデータストアから取得するので空でもゲームプレイに支障はない & アプリケーションはElastiCacheのReaderEndpointを見ているため分散可能という理由から、まずはElastiCacheのnodeを増やす対応をしました。
- nodeを増やした結果、少しは分散しました。分散後もまだ解決したと言えるような負荷状況ではないんですが、ElastiCacheクラスタはシャードあたりのノード数が[6個まで](https://docs.aws.amazon.com/ja_jp/general/latest/gr/elasticache-service.html)が限界なのでnode数的にはかなり限界に近い状態です。

![](https://storage.googleapis.com/zenn-user-upload/zt5csq9an8qkgx4wl18yrknnkcc5 =400x)

## 発生した問題その2: ElastiCacheメモリ枯渇問題

### 検知契機
- CPUUtilizationに加え、メモリの減りが異常なことにも気づきました。グラフの矢印の箇所あたりでは、メモリ使用量は落ち着くかと思いきや、その後すぐに単調減少の傾向になり、気づけばあと2時間でElastiCacheのメモリが枯渇するという状況に。
  - Redisは何ならメモリ使用量50%で危険域とも言われているので既に瀕死状態と言えます。

![](https://storage.googleapis.com/zenn-user-upload/f5h4arejfza51utepvh5kzq4hjj6 =400x)
![](https://storage.googleapis.com/zenn-user-upload/2e8vdm41lkaj5zs05gxn6x8a1ngb =400x)

### 調査内容
- どのようなキーの使い方をしているか調査しなければなりません。ここではRedisの `monitor` コマンドで一瞬だけキーの中身を調査しました。

:::message alert
このようなときにKEY一覧を取得する `keys *` コマンドを実行してはいけません。上記のグラフの180万件のKey全てを取得しようとし、他のgetが応答不能になり、ゲーム内でエラーが発生してしまう可能性が高いでしょう。もちろんmonitorコマンドを実行すること自体にも負荷がかかるので、実行は一瞬だけ。
:::

### 調査結果
- monitorコマンドを調査した結果、setコマンドでおかしい箇所が3点ほど見受けられました。
    1. 動的に生成されるキー名
        - DBに保存されているマスタデータのwhere句の組み合わせで、キーの名前を動的に生成してキャッシュするようなちょっと難しい使い方をしていました。さらに組み合わせ爆発を起こしそうな使い方にもなっていました。
    2. 同じキーが何度もsetされている
    3. setされている中身が空

:::message
本来はmonitorコマンドの結果を見ながら、何がおかしいか分析するプロセスに価値があると思うのですが、ゲームタイトルに紐づく名称が多々出てくるので、monitorコマンドの実行結果は出すのを控えております。
:::

### 対応
- まずはメモリ圧迫に影響していそうな、1.の組み合わせ爆発を起こしているキー名の対応をしました。DBに保存されているマスタデータのwhere句の組み合わせで、キーの名前を動的に生成してキャッシュするようなちょっと難しい使い方をしており、その結果、とんでもなく大量のキーがsetされており（グラフから、キー全体の総数は180万件以上あることが分かると思います)、これがメモリ圧迫の原因でした。また、キャッシュ元のRDSのreadはまだまだスケールできそうな状態だったので、これらのクエリをキャッシュしないようサーバコードを書き換え、デプロイして解決しました。
- グラフ内で一瞬メモリが減っているのはEvictionが発生したわけではなく、デプロイまでの間にflushdb( 計算量O(N) )をしながら瞬断を許容し、だましだまし運用しているグラフです...

![](https://storage.googleapis.com/zenn-user-upload/3e7etsjzthgf075wj1tsypvi6dvl =400x)

## 発生した問題その3: 次のイベントopen時に負荷やばそう問題

### 検知契機
- ElastiCacheのCPUUtilizationが火を吹きまくっていたのは上記の通りですが、翌日から新しい新規イベントオープンを予定しており、さらに追加でget/setが実行される見込みがあり、事前に手を打つ必要がありました。

### 対応
- このような場合はRedisの垂直分割が王道な案かと思いますが、今回は見送りました。その代わり、元々言っていた怪しい箇所2. 3. (同じキーが何度もsetされている問題 / setされている中身が空問題) を対応しました。
- これはつまり、空のキーをキャッシュした結果、getして空なのでまたsetするという、無限set問題が発生しているということです。全く意味のない余計な処理なので、これをキャッシュしないように修正し、イベント開始直前ギリギリにデプロイして乗り切りました。以下のグラフはsetコマンドの発行回数グラフで、デプロイ後にしっかり発行回数が抑止されていることが分かります(ギリギリのデプロイ)

![](https://storage.googleapis.com/zenn-user-upload/fcsj93etq3gy5hd457z48p9u1a31 =600x)

### おまけ: ElastiCacheのオンラインスケールアップ
- 翌日のイベントオープン時にCPUUtilizationがやばそう問題が議論になった際に、チームメンバーの1人が夜中にRedisのスケールアップを試みていました。が、先程も書いたとおり、RedisのクラスアップはCPUUtilizationの分散としてはあまり意味がありません。
    - （意味がない...とは言いつつも、このプロジェクトのRedisの使い方はかなり帯域を消費する使い方なのと、クラス変更するとネットワーク帯域が強力なインスタンスに変わるので、ちょっとだけ意味はあると思います）
- が、結果的に、[ElastiCache(Redis)のオンラインスケールアップ](https://dev.classmethod.jp/articles/can-elasticache-onlinescalingup-without-downtime/) の実績が詰めましたw

## EC2: ゲームサーバ編
![](https://storage.googleapis.com/zenn-user-upload/cknn9tzgs00tt4jhv20lj05mk227 =80x)

## 発生した問題: ファイルディスクリプタ単調増加問題

### 検知契機
- 監視していて検知しました。特定の数台だけfdが単調増加しており、このまま放置するとエラーになりうる状態でした。

![](https://storage.googleapis.com/zenn-user-upload/mt7002mc3hbdsb6ahsvbcj0b5fny =400x)

### 調査内容
- 何がfd掴んでいるのか `/proc/$pid/fd` を調査し、 `/usr/bin/dockerd` がsocketを掴みまくっていることが分かりました。

### 対応
- これは特定のECSインスタンスを再起動してリカバリするだけです。ECS instance再起動方法は色々ありますが、以下の3パターンを提案し、2個目の手順で再起動しました。
```
1. ECS instance draining & EC2 restart & ECS instance アクティブ化
2. ALB detach & EC2 restart & ALB attach
3. ECS instance draining & ecs agent stop & docker deamon restart & ecs agent start & ECS instance アクティブ化
```
- 全台で共通的に発生しているわけではなく、かつ他に優先度高いタスクがいっぱいあったのでこの問題はリカバリして終了。
- fdの監視大事ですね。このあたり簡単に監視できるDatadog恩恵あざっす。再起動手順のHow toを色々持っておくと状況に応じて柔軟に対応できて便利です。

## EC2: ログ基盤編
![](https://storage.googleapis.com/zenn-user-upload/8jqj9dtcfhxr3s2qyg8n9b4atzbb =160x)

## 発生した問題: fluentd bufferにファイル貯まりまくる問題

### 検知契機
- ふとボイスチャットから遠くの方でこんな声が聞こえてきました...「XXXさん、ログ分析基盤ってデータ反映遅れてたりします...？何か1時間ぐらい前から情報がなくて...」
- 怪しいと思って見てみると、しっかりfluentdのbuffer queueがめっちゃ貯まってました。

![](https://storage.googleapis.com/zenn-user-upload/h50qqpfjl84xaveeon4z3ru0id5d =400x)

### 調査内容
- fluentdのログを調査したら、BufferOverflowErrorが出まくっていました。

```
[error]: #0 suppressed same stacktrace
[warn]: #0 failed to write data into buffer by buffer overflow action=:throw_exception
[warn]: #0 emit transaction failed: error_class=Fluent::Plugin::Buffer::BufferOverflowError error="buffer space has too many data" location="/opt/td-agent/embedded/lib/ruby/gems/2.4.0/gems/fluentd-1.11.1/lib/fluent/plugin/buffer.rb:277:in `write'" tag="action_log.log_player_item"
```

- `buffer space has too many data` というメッセージを見て一瞬ストレージが圧迫？と思いましたが、ストレージは問題ありませんでした。
- BufferOverflowErrorはfluentdの bufferファイル出力より fluentdへの入力が大きい場合などで発生します。file bufferを見ると、timestampが1時間とか2時間前のファイルが大量に溜まっていたので、完全に入力の方が大きく詰まっている状態だと判断しました。

### 対応
- シンプルにサーバ数が足りなさそうだったので、EC2スケールアウトで対応しました。
- またworker数を見てみると、1workerで動いており、workerを増やすともう少しリソースを効率的に使えスループットが上がりそうでした。が、オンラインでいきなりmulti workerに変更するとfile bufferのパスが変わり、変更前に貯まっていたbufferが送信されないリスクがあるので、multi workerは今後のメンテ時に対応してもらうことにしました。
    - 例： multi workerに変更すると、以下のようにbufferパスが変わってしまい、旧bufferに貯まっていたfile bufferが送信されない状態になります。(手動でfile bufferをmvして再起動すればOKなんですがそれは置いておく)

```
- single worker:  /var/log/fluentd/buffer/<buffer name>/**
-  multi worker:  /var/log/fluentd/workerX/buffer/<buffer name>/**
```

- 他にも改善点としてはfluentd自体のログも監視できていることが望ましいです。送信のリトライし続けていることなども検知できるので。

## CloudWatch編
![](https://storage.googleapis.com/zenn-user-upload/b76fdxjcd289zlto5lv6hvojqwgr =80x)

## 発生した問題: CloudWatchコスト爆増問題

### 検知契機
- サーバアプリケーションログを見たい。が、コンテナ内にぱっと見当たりませんでした。コンテナの設定を見ると、log driver(fluent bit)が、直接CloudWatch Logsにログ送信するアーキテクチャでした。
- だが、ふと思いました。…これ、コスト爆増じゃね？

### 調査内容
- Cost Explorerを見てみると...Oh...やはり...CloudWatchのコストが爆増で、RDSより高いというとんでもない状態に...

![](https://storage.googleapis.com/zenn-user-upload/vq2ac3nosaoi9myir8m32qg5bugf)

- さすがにアプリケーションログのような大量のログを送信するとPutLogEventsがめっちゃ高いです。1週間で70万近い使い方...

![](https://storage.googleapis.com/zenn-user-upload/gt4h0g43z3tb7n3192sw5iz43dxc)

### 対応
- infoログはCloudWatchに送信せずS3に送信し、warn/errorのみCloudWatchに送信で良いのでは？と提案し、改修することに。
- トラブル内容は以上です。


# これらの問題を起こさないためには
- これらの問題を起こさないためにはやはり負荷テストが大事です。今回書いた全てのトラブルは事前の負荷テストで検知して対策が打てる内容です。負荷テストでよくあるのはアプリケーションボトルネックを見つけたり、想定する最大トラフィックを処理できるようなインフラ規模感をサイジングするといったことがありますが、今回の事例で言うと、丸1日負荷テストを流し続ける、といった長時間負荷テストを実施していれば、事前にこれらの問題を検知できていたかと思います。
- 具体的には、以下のような事前準備とチェックを行います。

#### 事前準備
- 新しいプレイヤーが新規参入しながら、継続的に負荷をかけつづけられるような負荷テストツールの準備。今のご時世、ちょっとやそっとの負荷テストじゃAWSには怒られません。
:::message
[1Gbps / 1Gpps](https://aws.amazon.com/jp/ec2/testing/) を超えるような負荷テストだと申請が必要になります。
:::
- プレイヤーが最大リソースを保持するようなデータの準備。事前にデータを入れておくのはかなり大変なので、デバッグAPIのようなものを用いて、負荷テストのシナリオ内でリソースを大量付与しちゃうのも手です。(少し負荷傾向に影響が出てしまいますが)
- 負荷テスト環境でリソースの傾向を観測できるような監視ダッシュボード。
- 何度でも壊して作り直せるインフラ(コード管理)。

#### テスト観点
以下のような観点でチェックすると良いでしょう。
- CPU/メモリ/ストレージ/fdなど、各種リソースが単調増加するような傾向になっていないか。同じトラフィックを流し続けているのにCPUUtilizationが単調増加することなんてあるの？って思うかもしれませんが、DBのレコード量に依存して重くなるクエリなんてものを書いてると発生します。(なので負荷テスト初期段階ではSlowクエリが発生していないので安心していたら、長時間負荷テストの最後の方ではSlowクエリが発生していた、なんてことも)
- 負荷テスト中にゲームのマスタデータ等をデプロイしても問題にならないか
- ログ基盤が問題なくさばけているか
- CloudWatch Logs料金のコスト感

などなど。他にも過負荷テストをしたり、障害テストをすることが望ましいですが、その話は別の記事におまかせするとします。


# 余談: コミュニケーションの工夫編
- 今回、突然のJOINだったため、コミュニケーションに非常に気をつけました。既存の開発メンバーの方々からしたら、リリース時に突然第三者にサーバ監視されているような状況なので、すごく嫌な気持ちになると思います。なので、普通に質問するだけでも、プレッシャーになる可能性があるので、質問を極力減らし提案型のコミュニケーションを意識しました。仕様や実装に関する質問をどうしてもしなければいけないときも、実装できてなくても恥ずかしくならないようなコミュニケーションを意識しました。

#### 個人的NGパターン
-  「AutoScalingGroupって設定しているんですか？」
- これは設定できていない場合に、相手が「できてないです」と返答するのにプレッシャーがかかるのでNG。してないって言うことでダサいって思われそうな心理が働くと思います。突然第三者がJOINした状況下、かつ顔も分からないオンライン状況下で心理的安全性という言葉は存在しません。

#### 気をつけた例
- 「AutoScalingGroupをもし設定されている場合は、自動復旧可能なのでXXXの対応で復旧可能です。もし設定されてないようであれば、YYYをした後にZZZをすれば復旧できます」
- これは相手に返答がいらないのでコミュニケーション負担にならないかつ、設定しててもしてなくてもどっちでもいいので、そんなことは置いといてリカバリの話やHow Toの提案に持っていくことで、設定してないことによる恥ずかしさが発生しないようなコミュニケーションを意識しました。

# まとめ
- この記事は、あるゲームプロジェクトの本番トラブルを題材に、トラブルシュートのプロセスや、どのような準備をしていれば防げたのかという話を書きました。結論は、負荷テストをすれば防げるということですが、今回かなりあるあるなトラブルが多発したので、トラブルシュートのプロセス自体も価値があるかと思い記事にしてみました。何かのお役に立てれば幸いです。
