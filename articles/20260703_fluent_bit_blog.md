---
title: "CloudWatch Logs のコストを月 100 万円削減した話 (EKS × fluentbit)"
emoji: "📉"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["AWS", "CloudWatch Logs", "fluentbit", "Kubernetes", "EKS"]
published: false
---

## はじめに

[TROCCO](https://trocco.io) は顧客のデータ転送を 1 日 25 万回以上実行する ETL プラットフォームです。

SRE チームでは以前から CloudWatch Logs のコストが高い課題感がありました。
今回コスト課題に取り組んだところ、100 万円/月 のコスト削減をしたため、事例の共有です。(ドル円 160 円換算)

以下は最終的に達成した Cost Explorer の図です(CloudWatch Logs のみを選択した状態)。大きくコスト削減できていることが分かります。

![](https://static.zenn.studio/user-upload/b04360a306a4-20260731.png)


今回、1 個の改善ではなく、いくつかの施策を組み合わせることで、100 万円/月のコスト削減を達成しました。
- fluentbit の改善(今回の話): 月 50 万
- 別の改善 1: 月 35 万
- 別の改善 2: 月 11 万
- 別の改善 3: 月数万

全ての解説ができればよいですが、ワークロード依存の部分もあるため、
本記事では、汎用性が高い fluentbit のアプローチについて事例をご紹介します[^1]。

[^1]: fluentbit だけの解説であれば月 50 万分の削減のため、記事のタイトルとしては月 50 万削減が正確なのですが、グラフを見ていただけると分かる通り、実際に一連の流れで月 100 万近く削減し、月 100 万削減したうちの 1 つを紹介します、という位置づけなので、タイトルは月 100 万としています。


## 初期のログ構造

顧客の ETL 処理を担うデータ転送ジョブは EKS の Kubernetes Job で動いており、標準出力を CloudWatch Logs に送っています。

ログから、どの pod で出力されたかを識別するために、送信前に fluentbit の [Kubernetes フィルタ](https://docs.fluentbit.io/manual/data-pipeline/filters/kubernetes) で Kubernetes の情報を付与しています。

しかし、画像のとおり、アプリケーションのログ 1 行ごとに Kubernetes のメタデータが大量に付与される構造になっていました。

![](https://static.zenn.studio/user-upload/6609e76fec3a-20260801.png)


## 改善1. Kubernetes メタデータ削減

`Kubernetes` フィルタは、詳細な情報を付与してくれる一方で、使わないデータも多くあります。
fluentbit では Lua で自作フィルタを埋め込むことができるため、必要なメタデータを精査し、不要なメタデータを削ることにしました。[^2]

[^2]: `Labels Off` といった、一括で情報を付与しない設定などあるのですが、必要なカスタムラベルもあり、一括でオフにはできないため、自作 Lua で必要なものだけをフィルタしています。

例:
```lua
function filter_kubernetes_metadata(tag, timestamp, record)
  record["stream"] = nil
  record["_p"] = nil

  if record["kubernetes"] then
    local k = record["kubernetes"]
    k["pod_id"] = nil
    k["docker_id"] = nil
    k["container_hash"] = nil
    -- ...
    -- カスタムラベル含め、30項目近くのラベルを除去
    -- ...
  end
  return 2, timestamp, record
end
```

以下のようにフィルタに追加すれば完了です。

```ini
[FILTER]
    Name    lua
    Match   var.log.containers.*
    script  /fluent-bit/etc/filter-kubernetes-metadata.lua
    call    filter_kubernetes_metadata
```

この修正でメタデータを大きく減らすことができました。

![](https://static.zenn.studio/user-upload/1847bd35a0a0-20260807.png)

## 改善2. 大規模なログの制限

メタデータの削減とは別に、ログのサイズそのものに起因する問題も見つかりました。
fluent-bit のログには以下の warning がごくまれに出ていました。

```
Truncating event which is larger than max size allowed by CloudWatch
```
```
Discarding massive log record
```

CloudWatch Logs は 1MB 以上のログを受け付けません。
1MB は相当大きいログですが、アプリケーション内で 1MB ものログを出力するような箇所は見たりません。調査すると、顧客の特殊な環境に依存した大規模なログが原因で 1 行 1MB のログが出力されていました。

TROCCO では顧客に見せるデータ転送の実行ログは CloudWatch Logs 以外の別経路で保存しています。
fluent-bit 側を通るログはシステム運用管理者向けの調査ログ用途のため、不要なものは積極的に削れます。

そのため思い切って 1 行が 1KB を超えたら先頭 1KB で切り詰める Lua フィルタを追加しました。
(これだと問題が残っているため後で改良します)

```lua
function truncate_massive_log(tag, timestamp, record)
  local log = record["log"] or ""
  if #log > 1024 then
    record["log"] = log:sub(1, 1024) .. "...(truncated)"
    return 2, timestamp, record
  end
  return 0, 0, 0
end
```

### 補足: fluent-bit のバージョンに注意

:::message
CloudWatch Logs は 2025/4 に 1MB のログサイズを [サポート](https://aws.amazon.com/jp/about-aws/whats-new/2025/04/amazon-cloudwatch-logs-increases-log-event-size-1-mb/) しましたが、fluentbit が 1MB 以上に対応しているのは 2025/12 にリリースされた [v4.2.2](https://fluentbit.io/announcements/v4.2.2/) 以降です。
:::


## 改善3. ログの multiline 化

k8s のメタデータを削り、1 行のサイズを制限しても、まだ不十分で「小さく 1 行ごとに送信する」オーバーヘッドが気になっていました。k8s のメタデータを削ったとはいえ、CloudWatch Logs へのログ送信は 1 レコードごとに k8s のメタデータが乗るため、行数が多いほど非効率になります。

そのため同一 pod のログを複数行をまとめて送る仕組みを作りました。

例えば `Rails.logger.info` を数回実行しても、fluentbit 側でバッファリングして複数行をまとめて 1 イベントとして CloudWatch Logs に送ります。
これにより k8s メタデータの送信量がさらに減ることが期待できます。

![](https://static.zenn.studio/user-upload/f5511e29aa87-20260807.png)


なおデータ転送ジョブは実行ごとに pod が分離されているため、同一 pod 内のログをまとめても他のデータ転送ジョブの情報が混在する心配はありません。

設定は以下のとおりです。

```ini
[MULTILINE_PARSER]
    name                    concat_logs_until_timeout
    type                    regex
    flush_timeout           3000
    rule                    "start_state"  "/./"  "cont"
    rule                    "cont"         "/./"  "cont"
```

```ini
[FILTER]
    Name                    multiline
    Match                   var.log.containers.*
    multiline.key_content   log
    multiline.parser        concat_logs_until_timeout
    mode                    parser
    buffer                  on
    flush_ms                3000
    emitter_name            multiline_container_logs
    emitter_storage.type    filesystem
```

```ini
[SERVICE]
    multiline_buffer_limit  200KB
```

ここでは全ての行をグループ化する parser を追加しています。

正規表現 `/./` が任意の 1 文字にマッチするため、「すべての行を 1 つのグループとして連結する」という強引な設定ですが、顧客のジョブごとに pod が分かれているため、負荷はともかくデータ整合性の観点では問題になりません。

3 秒ごと、または 200KB ごとにたまったログをまとめて 1 イベントとして出力することで、複数行をまとめて送ることができます。

pod のログ以外に kubelet や containerd など systemd のログも同様に multiline 化しました。

## multiline 化の副作用その1: timestamp 不整合

multiline の設定には副作用もありました。

複数行を連結すると、fluentbit および CloudWatch Logs の timestamp が意図せぬ時間になり、実際のログ出力時間と全く異なる時間を指し示すようになりました。

例えば 1 個前のログの最終時刻や、in_tail でログを watch し始めた時間など、いろんなパターンで timestamp が壊れたため、対処として flush 時点の時刻で timestamp を上書きすることで解決しました

```lua
function patch_timestamp(tag, timestamp, record)
  return 1, os.time(), record
end
```

3 秒ごとの flush のため、実際のログの時刻と、CloudWatch Logs の timestamp が 3 秒ほどズレてしまうデメリットがありますが、コストメリットの恩恵の方が大きいためデメリットを受容することにしています[^3]。
CloudWatch Logs 上のイベント timestamp が 3 秒ずれるだけで、実際のログの中身には厳密な時刻が記載されており、ログの中身を見ればよいだけで、トラブルシュート時も大きな問題にはならないはずとチーム内で合意を取っています。

[^3]: 厳密には Lua スクリプトの `os.time()` もミリ秒が欠落してしまうのですが、そもそも 3 秒ずれを許容しているため、こちらも許容しています。

## multiline 化の副作用その2: 重複実行リスク

これが一番の引っかかりポイントでした。
fluentbit には emitter という内部の組み込みプラグインがあります。

この挙動が複雑で、multiline で複数行をまとめて buffer flush するタイミングで、emitter がログを fluentbit の ログパイプラインの先頭に再出力します。

### 例
例えば以下のフィルタ設定をしているとします。
```
input tail
- filter A
- filter multiline
- filter B
```

このとき、実際の処理の流れとしては multiline を通ったあと先頭に再投入されるため filter A が 2 回実行されることになります。

```
input tail
- filter A
- filter multiline
- filter A (パイプラインの先頭からやりなおし)
- filter B (2 回目は multiline はスキップ)
```

そのため、fluentbit の[公式ドキュメント](https://docs.fluentbit.io/manual/data-pipeline/filters/multiline-stacktrace)にも強い注意書きがあります。


## 対処

「改善2. 大規模なログの制限」で実装した 1 行切り詰めの `truncate_massive_log` を、multiline parser 適用後のログが来ても冪等になるように実装しなおすことで対処しました。

fluentbit の公式ドキュメント上では multiline filter をパイプラインの最初に定義することで重複実行リスクがなくなる tips が記載されています。

しかし、我々は multiline filter をパイプラインの最初に定義せず、`truncate_massive_log` (1 行の長さ切り詰め) -> multiline フィルターの順番で定義しました。

理由は、もし multiline を先頭に定義した場合、今度は 1 行が非常に大きくなる可能性のあるログを複数行保持する buffer サイズの設計が必要になるためです。

フィルタが複数回実行されても、処理を冪等にすればリスクが小さい一方で、buffer 溢れはリスクが大きく、小さなバッファーを維持できる方がログ欠損リスクがなく安全と考えたためです。

`truncate_massive_log` は以下のように修正しました。
厳密にはもう少し細かい実装があるのですが、ブログ上のコードスニペットとしてはわかりやすさのため短くしています。

```lua
  local lines = {}

  -- \n が出てくるまでの文字列にマッチさせる = \n で分割するのと同義
  for line in log:gmatch("[^\n]+") do
    if #line > 1024 and not has_truncated_suffix(line) then
      line = line:sub(1, 1024) .. "...(truncated)"
    end
    table.insert(lines, line)
  end
end
```

## multiline 化の副作用その3: リソース増加


multiline 化実装後、fluentbit のリソースは大きく増えました。(実装中から少し嫌な予感を持っていました)

pod のリソースグラフを見ると、メモリ使用量が莫大に増えており、直感的には OOM リスクがあるように見えます。

![](https://static.zenn.studio/user-upload/d4046ffea330-20260807.png)

しかし、増えたメモリの中身 (`/sys/fs/cgroup/memory.stat`) をよく見ると、メモリキャッシュが溜まっているだけで、特に問題ないことが分かりました。

具体的には `slab_reclaimable` と呼ばれる解放可能なキャッシュが増えているだけで、メモリプレッシャーがかかった場合は、OOM ではなく、メモリが解放されて処理が継続します。

いくつかの pod を調べたところ、ほとんどが `slab_reclaimable` のような解放可能な領域だったため、グラフからは想像しがたいですが、特にリソースチューニングせずとも問題なく動いています。[^4]

[^4]: グラフの見た目上、初見の人がびっくりするかもしれないので、コメントなどは充実させています。

## 改善4. ログ監視追加

「改善2. 大規模なログの制限」で記載したようなログ欠損のようなメッセージが再発した場合や、buffer サイズを 200KB 制限にしているにもかかわらず、送信されるサイズが 200KB よりも大きい場合などで CloudWatch Alarm が通知されるようにしました。

Lua スクリプトで、multiline 化した後のログサイズが 200KB よりも大きなサイズになった場合、特定のアラート用のメタデータをログに付与し、CloudWatch Logs でメトリクスフィルターでアラート用のメタデータを検知した場合、CloudWatch Alarm をアラーム状態にする仕組みです。

## 最終的なフィルターパイプライン

最終的には以下のようなフィルターパイプラインになりました。

![](https://static.zenn.studio/user-upload/d2dff1af9549-20260807.png =400x)

## 成果

fluentbit の対策のみで、月 50 万のコスト削減を達成しました。

加えて同時に行ったその他の改善の積み重ねで、最終的に **100 万円/月** のコスト削減を達成しました。(ドル円 160 円換算)

![](https://static.zenn.studio/user-upload/b04360a306a4-20260731.png)

CloudWatch Logs は、コスト高のサービスかつ、気づけばじわじわ積み上がっていることが多いです。

fluentbit のチューニングでも大きくコストを削減できたため、みなさまもコスト削減チャレンジしてみてください。

では幸せなコスト削減ライフを！
