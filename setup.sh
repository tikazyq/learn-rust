#!/usr/bin/env bash
# Rust by Migration · 一键 git 初始化脚本
#
# 用法:
#   chmod +x setup.sh
#   ./setup.sh
#
# 之后按提示创建 GitHub repo 并推送即可。

set -euo pipefail

if [ -d ".git" ]; then
  echo "⚠️  这个目录已经是 git 仓库,跳过 init。"
else
  echo "→ git init"
  git init -q
  git branch -M main
fi

# 配置默认行为
git config core.autocrlf input

# 检查 user.email / user.name(没配的话提示)
if ! git config user.email > /dev/null; then
  echo "⚠️  git user.email 未配置。先跑:"
  echo "     git config --global user.email 'you@example.com'"
  echo "     git config --global user.name 'Your Name'"
  exit 1
fi

echo "→ git add ."
git add .

if git diff --cached --quiet; then
  echo "ℹ️  没有需要提交的改动。"
else
  echo "→ git commit"
  git commit -q -m "Initial commit: Rust by Migration mdBook scaffold

- mdBook 配置(book.toml,深色主题、搜索、可运行代码块)
- 完整 12 周学习计划
- 20 章骨架(Ch 1-6 含部分正文,Ch 7-20 大纲 + 待补标记)
- 附录 A-E 骨架
- GitHub Actions:mdbook build + mdbook test + 链接检查
- Vercel 配置:推送即自动部署"
fi

cat <<'INSTRUCTIONS'

✅ 本地 git 仓库已就绪。

接下来三步把它变成线上站点:

────────────────────────────────────────────
1️⃣  在 GitHub 创建空仓库
────────────────────────────────────────────
   打开 https://github.com/new
   - Repository name: rust-by-migration(或你想要的名字)
   - Public 或 Private 都可以(Vercel 都能接)
   - ⚠️ 不要勾选 "Add a README"、"Add .gitignore"、"Choose a license"
     —— 我们本地已经有了,勾了会产生冲突

────────────────────────────────────────────
2️⃣  推送
────────────────────────────────────────────
   把下面 USER 改成你的 GitHub 用户名:

     git remote add origin git@github.com:USER/rust-by-migration.git
     git push -u origin main

   (用 HTTPS 也行:git@github.com:USER/... → https://github.com/USER/...)

────────────────────────────────────────────
3️⃣  在 Vercel 接入这个 repo
────────────────────────────────────────────
   打开 https://vercel.com/new
   - 选择刚 push 的 rust-by-migration 仓库,点 Import
   - Framework Preset:Other(自动)
   - Build / Output / Install Command:全留空(读取项目里的 vercel.json)
   - Deploy

   ~30 秒后会拿到 https://xxx.vercel.app
   往后任何 .md 改动 → git push → Vercel 自动重新构建并部署。

────────────────────────────────────────────
🎁 加分项
────────────────────────────────────────────
   - 在 Vercel 项目设置里加自定义域名(免费)
   - GitHub 仓库设 Settings → Pages → 也能在 github.io 双发
   - 在 GitHub 仓库描述里贴 Vercel 站点链接

INSTRUCTIONS
