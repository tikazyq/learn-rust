# Rust by Migration —— mdBook 项目

> 从 Go / C# / TypeScript 到 Rust 的系统工程师转型

这是一本写给有 10+ 年工程经验、用 GC 语言到生产级、但没系统学过手动内存管理的工程师的 Rust 教材。

---

## 🚀 部署到 Vercel(推荐路径)

最佳协作姿势:**改 .md → git push → Vercel 自动重新构建并部署**。

```bash
./setup.sh
```

脚本会:

1. `git init` + 第一个 commit
2. 检查 `git user.email` / `user.name` 是否配置
3. 打印接下来三步的具体命令(GitHub 建仓 → push → Vercel 接入)

整个流程约 5 分钟,之后再不用碰 CLI。

---

## 💻 本地预览

### 安装 mdBook

```bash
cargo install mdbook
```

或下载预编译二进制:<https://github.com/rust-lang/mdBook/releases>

### 启动本地服务

```bash
mdbook serve --open
```

浏览器自动打开 `http://localhost:3000`,支持:

- 左侧目录导航(全章节折叠/展开)
- 顶部搜索框(`s` 快捷键)
- 代码块语法高亮、复制按钮、运行按钮(通过 Rust Playground)
- 浅色 / 深色主题切换
- 文件改动后自动重新构建并刷新浏览器

### 导出静态站点

```bash
mdbook build
```

输出在 `book/` 目录。

---

## 📂 目录结构

```
rust-by-migration/
├── README.md              # 本文件
├── setup.sh               # 一键 git init 脚本
├── book.toml              # mdBook 配置
├── vercel.json            # Vercel 构建配置
├── .gitignore
├── .github/
│   └── workflows/
│       └── build.yml      # CI:mdbook build + test + 链接检查
└── src/
    ├── SUMMARY.md         # mdBook 目录(入口)
    ├── introduction.md
    ├── plan/              # 12 周学习计划
    ├── part1/             # Part I 心智模型重置(Ch 1-3)
    ├── part2/             # Part II 类型系统(Ch 4-7)
    ├── part3/             # Part III 内存与资源(Ch 8-10)
    ├── part4/             # Part IV 并发与异步(Ch 11-13)
    ├── part5/             # Part V 工程实践(Ch 14-16)
    ├── part6/             # Part VI 深水区(Ch 17-20)
    └── appendix/          # 附录 A-E
```

---

## 📊 内容状态

| 章节 | 状态 |
|---|---|
| 12 周计划 | ✅ 完整 |
| 引言 / 大纲 | ✅ 完整 |
| Ch 1 为什么 Rust 不一样 | 🟡 部分(从对话历史恢复) |
| Ch 2 Ownership 是工程纪律 | 🟡 部分 |
| Ch 3 Borrowing 与 Lifetime | 🟡 部分 |
| Ch 4 Struct/Enum/Pattern Matching | 🟡 部分 |
| Ch 5 错误处理工程化 | 🟡 部分 |
| Ch 6 Trait | 🟡 部分 |
| Ch 7-20 | ⏳ 骨架 |
| 附录 A-E | ⏳ 骨架 |

🟡 / ⏳ 章节里每个待补段落都用 `⚠️ 本节正文待补` 标记,渲染后醒目可见。

---

## 🔄 CI / CD

GitHub Actions 工作流(`.github/workflows/build.yml`)在每次 push 和 PR 时:

1. **mdbook build** —— 验证整本书能构建
2. **mdbook test** —— 编译每个 ` ```rust ` 代码块,确保示例不会编译失败(标记 `ignore` / `no_run` 的除外)
3. **lychee link check** —— 扫描所有 .md 中的链接

CI 通过后 Vercel 自动部署。

---

## 🛠 个性化

- **主题色**:`mdbook init --theme` 生成 `theme/` 目录,改 `theme/css/variables.css`
- **可运行代码块**:rust 代码块默认可运行,关闭某段加 ` ```rust,no_run `
- **不参与测试的代码块**:加 ` ```rust,ignore `
- **Mermaid 图**:安装 `mdbook-mermaid` 预处理器
- **mathjax 公式**:在 `book.toml` 里 `mathjax-support = true`

---

## 📝 推荐工作流

1. 每天学习前 `mdbook serve` 开本地预览
2. 学完一章后,在该章末尾的"📝 学习记录"表格填日期 / 卡点 / 关键收获
3. 配套代码放到另一个 `rust-by-migration-code/` repo,链接贴回学习记录里
4. 一周一次 `git push` 触发 Vercel 重建,顺便复盘本周进展
