---
title: "CloudWatch Logs のコストを月 100 万円削減した (EKS × Fluent Bit)"
emoji: "📉"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["AWS", "CloudWatch Logs", "Fluent Bit", "Kubernetes", "EKS"]
published: false
---

## はじめに

[TROCCO](https://trocco.io) は顧客のデータ転送を 1 日 25 万回以上実行する ETL プラットフォームです。

以前から CloudWatch Logs のコストが高い課題感があり、コスト課題に取り組んだところ、100 万円/月 のコスト削減をしたため、事例の共有です。(ドル円 160 円換算)

以下は CloudWatch Logs のみを選択した Cost Explorer の図です。
大きくコスト削減できていることが分かります。

![](https://static.zenn.studio/user-upload/2365e94817ab-20260814.png)

今回、1 個の改善ではなく、いくつかの改善の積み重ねで、100 万円/月のコスト削減を達成しました。[^1]
- Fluent Bit の改善(今回の話): 月 50 万 削減
- 別の改善 1: 月 35 万 削減
- 別の改善 2: 月 11 万 削減
- 別の改善 3: 月数万 削減

全ての解説ができればよいですが、ワークロード依存の部分もあるため、
本記事では、汎用性が高い Fluent Bit のアプローチについて事例をご紹介します。

[^1]: Fluent Bit だけの解説であれば月 50 万分の削減のため、ややタイトル詐欺ですが、グラフを見ていただけると分かる通り、実際に一連の流れで月 100 万近く削減し、月 100 万削減したうちの 1 つを紹介します、という位置づけなので、タイトルは月 100 万としています。


## 初期のログ構造

ETL 処理を担うデータ転送ジョブは EKS の Kubernetes Job として動き、標準出力を CloudWatch Logs に送っています。1 つのデータ転送につき 1 つの Kubernetes Job を起動するため、pod はデータ転送ごとに分離しています。

調査用に pod 情報を残したく、CloudWatch Logs へ送る前に Fluent Bit の [Kubernetes フィルタ](https://docs.Fluent Bit.io/manual/data-pipeline/filters/kubernetes) でメタデータを付与していました。しかし画像のとおり、アプリケーションのログ 1 行ごとに Kubernetes のメタデータが大量に乗る構造になっていました。

![](https://static.zenn.studio/user-upload/6609e76fec3a-20260801.png)


## 改善1. Kubernetes メタデータ削減

`Kubernetes` フィルタは、詳細な情報を付与してくれる一方で、使わないデータも多くあります。
Fluent Bit では Lua で自作フィルタを埋め込むことができるため、必要なメタデータを精査し、不要なメタデータを削ることにしました。[^2]

[^2]: `Labels Off` といった、一括で情報を付与しない設定などがあるのですが、必要なカスタムラベルもあり、一括でオフにはできないため、自作 Lua で必要なものだけをフィルタしています。

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

```ini
[FILTER]
    Name    lua
    Match   var.log.containers.*
    script  /Fluent Bit/etc/filter-kubernetes-metadata.lua
    call    filter_kubernetes_metadata
```

この修正でメタデータを大きく減らすことができました。

![](https://static.zenn.studio/user-upload/1847bd35a0a0-20260807.png)

## 改善2. 大規模なログの制限

メタデータの削減以外に、そもそもログのサイズが大きい問題も見つかりました。
Fluent Bit のログには以下の warning がごくまれに出ていました。

```
Truncating event which is larger than max size allowed by CloudWatch
```
```
Discarding massive log record
```

これはログサイズが大きすぎる warning です。
CloudWatch Logs は 1MB を超えるログを受け付けません。

1MB というのは相当大きいログで、アプリケーション内で 1MB ものログを出力するような箇所はありません。調査すると、顧客の特殊な環境に依存した大規模なログが原因で 1 行 1MB のログが出力されていました。

TROCCO では顧客に提供するデータ転送の実行ログは CloudWatch Logs 以外の別経路で保存しており、Fluent Bit を通るログはシステム運用管理者向けの調査ログ用途のため、不要なものは積極的に削ることができます。

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

### 補足: Fluent Bit のバージョンに注意

:::message
CloudWatch Logs は 2025/4 に 1MB のログサイズを [サポート](https://aws.amazon.com/jp/about-aws/whats-new/2025/04/amazon-cloudwatch-logs-increases-log-event-size-1-mb/) しましたが、Fluent Bit が最大 1MB に対応しているのは 2025/12 にリリースされた [v4.2.2](https://Fluent Bit.io/announcements/v4.2.2/) 以降です。
:::


## 改善3. ログの multiline 化

k8s のメタデータを削り、1 行のサイズを制限しても、まだ不十分で「小さく 1 行ごとに送信する」オーバーヘッドがありました。k8s のメタデータを削ったとはいえ、CloudWatch Logs へのログ送信は 1 レコードごとに k8s のメタデータが乗るため、ログを細かく put するほど非効率になります。

そのため同一 pod のログを複数行まとめて送る仕組みを作りました。

具体的にはアプリケーション内で `logger.info` を数回実行しても、Fluent Bit 側でバッファリングして複数行をまとめて 1 イベントとして CloudWatch Logs に送る仕組みです。
これにより k8s メタデータの送信量がさらに減ることが期待できます。

![](https://static.zenn.studio/user-upload/f5511e29aa87-20260807.png)

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

正規表現 `/./` が任意の 1 文字にマッチするため、「すべての行を 1 つのグループとして連結する」という強引な設定ですが、顧客のデータ転送ジョブごとに pod を分離しているため、他のデータ転送ジョブの情報が混在する心配はありません。

3 秒ごと、または 200KB ごとにたまったログをまとめて 1 イベントとして出力することで、複数行をまとめて送る設定にしています。

multiline 化はコストメリットが大きかったため、pod のログ以外に kubelet や containerd などのログも同様に multiline 化しました。

## multiline 化の副作用その1: timestamp 不整合

multiline の設定には副作用もありました。

複数行を連結すると、Fluent Bit および CloudWatch Logs の timestamp が意図せぬ時間になり、実際のログ出力時間と全く異なる時間を指し示すようになりました。

例えば CloudWatch Logs の timestamp が全て in_tail でログを watch し始めた時間になるなど、いろんなパターンで timestamp が壊れたため、対処として flush 時点の時刻で timestamp を上書きすることで解決しました。

```lua
function patch_timestamp(tag, timestamp, record)
  return 1, os.time(), record
end
```

3 秒ごとの flush のため、実際のログの時刻と、CloudWatch Logs の timestamp が 3 秒ほどずれてしまうデメリットがありますが、コストメリットの方が大きいためデメリットを受容することにしています[^3]。
CloudWatch Logs 上のイベント timestamp が 3 秒ずれるだけで、実際のログの中身には厳密な時刻が記載されており、ログの中身を見ればよいだけで、トラブルシュート時も大きな問題にはならないはずという判断です。

[^3]: 厳密には Lua スクリプトの `os.time()` もミリ秒が欠落してしまうのですが、そもそも 3 秒ずれを許容しているため、こちらも許容しています。

## multiline 化の副作用その2: 重複実行リスク

Fluent Bit には emitter という内部の組み込みプラグインがあり、設定したフィルタの意図せぬ重複実行リスクがあります。

この挙動が複雑で、multiline 化したログを buffer flush するタイミングで、emitter がログを Fluent Bit のログパイプラインの先頭に再出力します。

Fluent Bit の[公式ドキュメント](https://docs.Fluent Bit.io/manual/data-pipeline/filters/multiline-stacktrace)にも強い注意書きがあります。
(重複実行だけでなく無限ループリスクも！)


### 例
例えば以下のフィルタ設定をしているとします。
```
input tail
- filter A
- filter multiline
- filter B
```

このとき、filter multiline を通ったあと、ログが先頭に再投入されるため filter A がもう一度実行されることになります。(2回目は filter multiline はスキップ)

```
input tail
- filter A
- filter multiline
- filter A (パイプラインの先頭からやりなおし)
- filter B (2 回目は multiline はスキップ)
```

この再実行によって「改善2. 大規模なログの制限」で実装した 1 行切り詰めで問題が起こり

- ログを 1 行 1KB に切り詰め
- multiline 化 (複数行を \n で結合)
- multiline 化した大規模なログ全体を 1KB に切り詰め、ログ欠損。

という問題が起きてしまいました。

## 対処

「改善2. 大規模なログの制限」で実装した 1 行切り詰めの `truncate_massive_log` を、multiline parser 適用後のログが来ても冪等になるように実装しなおすことで対処しました。

Fluent Bit の公式ドキュメント上では multiline filter をパイプラインの最初に定義することで重複実行リスクがなくなる tips が記載されています。

しかし、我々は multiline filter をパイプラインの最初には定義せず、`truncate_massive_log` (1 行の長さ切り詰め) -> multiline フィルタの順番で定義しました。

理由は、もし multiline を先頭に定義した場合、今度は 1 行が非常に大きくなる可能性のあるログを複数行保持する buffer サイズの設計が必要になるためです。

フィルタが複数回実行されても、処理を冪等にすればリスクが小さい一方で、buffer 溢れはリスクが大きく、小さなバッファを維持できる方がログ欠損リスクがなく安全と考えたためです。

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


multiline 化実装後、Fluent Bit のメモリ使用量が大きく増えました。(実装中も少し嫌な予感を持っていました)

しかし、増えたメモリの中身 (`/sys/fs/cgroup/memory.stat`) をよく見ると、メモリキャッシュが溜まっているだけで、ほとんど問題ないことが分かりました。

具体的には `slab_reclaimable` と呼ばれる解放可能なメモリ領域が増えているだけで、メモリプレッシャーがかかった場合は、OOM ではなく、メモリが解放されて処理が継続します。

実際にメトリクスを観測していると、メモリ使用量が pod の limit に近づいた場合、OOM ではなく、メモリ使用量が大きく減る(キャッシュが解放される)挙動をし、これが繰り返されるだけ、かつ、いくつか pod を調査したところ `slab_reclaimable` が支配的であることを観測したため、特にリソースチューニングせずとも問題なく動いています。

## 改善4. ログ監視追加

「改善2. 大規模なログの制限」で記載した、ログサイズが大きすぎる warning が再発した場合や、buffer サイズを 200KB 制限にしているにもかかわらず、送信されるサイズが 200KB よりも大きい場合などで CloudWatch Alarm が通知されるようにしました。

Lua スクリプトで、multiline 化した後のログサイズが 200KB よりも大きなサイズになった場合、アラート用のメタデータをログに付与し、CloudWatch Logs メトリクスフィルタ + CloudWatch Alarm で通知する仕組みです。

## 最終的なフィルターパイプライン

最終的には以下のようなフィルターパイプラインになりました。

![](https://static.zenn.studio/user-upload/d2dff1af9549-20260807.png =400x)

## 成果

Fluent Bit の対策のみで、月 50 万のコスト削減を達成しました。

加えて Fluent Bit 以外に同タイミングで行ったその他の改善の積み重ねで、最終的に **100 万円/月** のコスト削減を達成しました。(ドル円 160 円換算)

![](https://static.zenn.studio/user-upload/2365e94817ab-20260814.png)

CloudWatch Logs は、コスト高のサービスかつ、気づけばじわじわ積み上がっていることが多いです。

Fluent Bit のチューニングでも大きくコストを削減できたため、みなさまもコスト削減チャレンジしてみてください。

では幸せなコスト削減ライフを！
