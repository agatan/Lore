#!/bin/bash
# 「Koe Dev」という自己署名のコード署名証明書を login キーチェーンに作る。
#
# なぜ必要か: ad-hoc 署名(codesign -s -)は identity が cdhash 自身なので、
# リビルドするたび別アプリ扱いになり、アクセシビリティの許可が毎回無効になる。
# 固定の identity で署名すれば designated requirement が安定し、許可が残る。
#
# 実装メモ:
# - PKCS12 を経由しない。OpenSSL 3 の既定の MAC/PBE は Apple の Security framework が
#   読めず "MAC verification failed" になるため、鍵と証明書を個別に import する。
# - 信頼設定(add-trusted-cert)は不要。自己署名は CSSMERR_TP_NOT_TRUSTED のままだが、
#   codesign は問題なく使える(Gatekeeper 用ではなくローカル実行用なので十分)。
set -euo pipefail

NAME="Koe Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
	echo "既にあります: $NAME"
	exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = Koe Dev
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "自己署名証明書を作成します…"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
	-keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" 2>/dev/null

echo "キーチェーンに登録します(許可を求めるダイアログが出たら許可してください)…"
security import "$TMP/key.pem" -k "$KEYCHAIN" -T /usr/bin/codesign
security import "$TMP/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign

if ! security find-identity -p codesigning | grep -q "\"$NAME\""; then
	echo "失敗: identity が見つかりません。Keychain Access の 証明書アシスタント から" >&2
	echo "      「Koe Dev」という名前でコード署名用の自己署名証明書を作ってください。" >&2
	exit 1
fi

# 署名のたびにキーチェーンの確認ダイアログが出ないようにする。
#
# キーチェーンのパスワードが必要で、`security` は端末に直接プロンプトを出す
# (リダイレクトでは隠せない)。そのプロンプトには「(deprecated)」と付くが、
# 非推奨なのは security コマンドの対話式入力であって、証明書や署名には影響しない。
echo
echo "キーチェーンのパスワードを入力してください(署名時の確認ダイアログを抑止するため)。"
echo "  プロンプトに (deprecated) と出ますが、security コマンドの入力方式の話なので問題ありません。"
echo "  空 Enter でスキップしても構いません(その場合は初回の署名時に「常に許可」を選んでください)。"
if ! security set-key-partition-list \
	-S apple-tool:,apple:,codesign: -s "$KEYCHAIN" >/dev/null 2>&1; then
	echo "note: 抑止できませんでした。署名時のダイアログでは「常に許可」を選んでください"
fi
echo

echo "完了: $NAME で署名します。次に:"
echo "  make reset-permissions && make install"
