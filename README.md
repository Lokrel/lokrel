<div align="center">

# Lokrel

**A native macOS asset manager for local 3D printing model libraries.**  
**本地 3D 打印模型库的原生 macOS 资源管理器。**

Current version / 当前版本: `1.1.2`

[Download / 下载](#download--下载) · [Documentation / 文档](https://lokrel.github.io/lokrel/) · [Donate / 捐赠](#donate--捐赠)

</div>

**3D Print Asset Manager · 3D 打印模型资源管理器**

lokrel 用照片管理软件的方式整理 3D 打印模型。一个模型以及它的 3MF、STL、STEP、图片、PDF 和 README 会尽可能合并成一个项目，而不是散落成许多独立文件。

lokrel organizes 3D-printing models like a photo library. A model and its related 3MF, STL, STEP, image, PDF, and README files are presented as one project whenever possible.

---

## Download / 下载

### System Requirements / 系统需求

- macOS 14 Sonoma or later / macOS 14 Sonoma 或更新版本
- Apple Silicon Mac only (ARM64: M1/M2/M3/M4 or later) / 仅支持 Apple 芯片 Mac（ARM64：M1/M2/M3/M4 或更新）
- Intel Macs are not currently supported / 暂不支持 Intel Mac

### macOS (Apple Silicon) / macOS（Apple 芯片）

- 📦 **GitHub Releases (Recommended) / GitHub Releases（推荐）**  
  https://github.com/Lokrel/lokrel/releases

### 百度网盘下载 / Baidu Netdisk Download

- ☁️ **Baidu Netdisk / 百度网盘**  
  https://pan.baidu.com/s/144ne-4VZO2kAt4ABlNvDbA  
  Extraction Code / 提取码: `0t7e`

---

## 快速开始

1. 打开 `lokrel.app`。
2. 点击“Choose Folder…”并选择存放模型的顶层目录。
3. 等待扫描完成，即可使用网格或列表浏览。
4. 点击任意模型，在右侧查看预览、文件、标签和备注。

以后再次打开 lokrel 时，已保存的资料库会立即显示，并在后台重新检查文件变化。也可以随时点击工具栏中的刷新按钮。

## Quick Start

1. Open `lokrel.app`.
2. Click “Choose Folder…” and select the top-level folder that contains your models.
3. Wait for scanning to finish, then browse in Grid or List view.
4. Select a model to see its preview, files, tags, and notes in the Inspector.

The saved library appears immediately the next time lokrel opens, followed by a background rescan. Use the refresh button at any time to rescan manually.

---

## 主要功能

- **模型项目**：同一目录中的同名 3MF、STL、STEP、OBJ、图片、PDF 和 README 会自动归组。
- **3MF 封面**：优先读取文件内置缩略图并缓存。
- **STL 预览**：纯 STL 模型会自动生成卡片缩略图；在 Inspector 中可拖动旋转、滚动缩放。
- **OBJ 预览**：OBJ 模型同样支持缩略图、材质读取和交互式 3D 查看。
- **丰富元数据**：显示文件属性、3MF 内置作者、许可、创建软件和厂商字段；显示名称、作者、来源链接、许可和描述可以在 lokrel 中修改。
- **自定义封面**：右键模型，可选择关联图片或本机 JPG/PNG。
- **目录浏览**：左侧 Folders 区域按照原始目录结构浏览模型。
- **搜索与整理**：按模型名、关联文件名或标签实时搜索；支持收藏、标签和备注。
- **打开与定位**：使用默认软件打开模型，或在 Finder 中显示原文件。

## Main Features

- **Model projects:** Matching 3MF, STL, STEP, OBJ, image, PDF, and README files in the same folder are grouped automatically.
- **3MF covers:** Embedded thumbnails are extracted and cached.
- **STL previews:** STL-only models receive generated card thumbnails. Drag to rotate and scroll to zoom in the Inspector.
- **OBJ previews:** OBJ models also support thumbnails, material loading, and interactive 3D viewing.
- **Rich metadata:** View file properties plus embedded 3MF author, license, source application, and vendor fields. Display name, author, source link, license, and description are editable inside lokrel.
- **Custom covers:** Right-click a model to use a related image or choose a JPG/PNG from your Mac.
- **Folder browsing:** The Folders section mirrors the original directory structure.
- **Search and organize:** Search model names, related filenames, or tags. Add favorites, tags, and notes.
- **Open and reveal:** Open a model in its default app or reveal the original file in Finder.

---

## 自动归组规则

- 只关联位于**同一目录**且主文件名相同的文件。
- `Holder.3mf`、`Holder.stl`、`Holder.step` 和 `Holder.jpg` 会显示为一个 `Holder` 项目。
- 当一个目录中只有一个模型项目时，`README.md` 会自动归入该项目。
- 封面优先级为：自定义封面 → 同名关联图片 → 3MF 内置缩略图 → STL/OBJ 渲染图 → 默认图标。

## Automatic Grouping Rules

- Files are grouped only when they are in the **same folder** and share the same base name.
- `Holder.3mf`, `Holder.stl`, `Holder.step`, and `Holder.jpg` appear as one `Holder` project.
- `README.md` is attached automatically when its folder contains only one model project.
- Cover priority: custom cover → related image → embedded 3MF thumbnail → rendered STL/OBJ thumbnail → default icon.

---

## 文件与隐私

lokrel 不会修改模型原文件。标签、收藏、备注和封面选择保存在本机数据库中；缩略图保存在本机缓存中。没有登录、上传或云同步。

当前目录树用于浏览和筛选。移动或重命名文件时，请使用 Finder；刷新后 lokrel 会重新识别目录内容。

## Files and Privacy

lokrel does not modify original model files. Tags, favorites, notes, and cover choices are stored in a local database, while thumbnails stay in the local cache. There is no account, upload, or cloud sync.

The folder tree currently supports browsing and filtering. Use Finder to move or rename files, then rescan lokrel.

---

## 当前支持

模型文件：`3MF`、`STL`、`STEP/STP`、`OBJ`、`F3D`、`IGES/IGS`  
关联文件：`JPG/JPEG`、`PNG`、`WEBP`、`PDF`、`MD`、`TXT`

lokrel 是资源管理器，不负责切片、打印或编辑模型。

## Currently Supported

Model files: `3MF`, `STL`, `STEP/STP`, `OBJ`, `F3D`, `IGES/IGS`  
Related files: `JPG/JPEG`, `PNG`, `WEBP`, `PDF`, `MD`, `TXT`

lokrel is an asset manager. It does not slice, print, or edit models.

---

## Donate / 捐赠

Donation options are not configured yet.  
捐赠方式暂未配置。

---

## 发布打包

`Scripts/release.sh` 会生成 `dist/archive/` 下的 `.app` archive，使用 Developer ID 签名并开启 Hardened Runtime，然后生成、签名、notarize、staple DMG。所有 Apple 凭据都从环境变量读取，不写入仓库。

```bash
export LOKREL_DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
export LOKREL_NOTARY_APPLE_ID="you@example.com"
export LOKREL_NOTARY_TEAM_ID="TEAMID"
export LOKREL_NOTARY_PASSWORD="xxxx-xxxx-xxxx-xxxx"
Scripts/release.sh
```

## Release Packaging

`Scripts/release.sh` creates an archived `.app` under `dist/archive/`, signs it with Developer ID and Hardened Runtime, then creates, signs, notarizes, and staples the DMG. All Apple credentials are read from environment variables and are not stored in the repository.

```bash
export LOKREL_DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
export LOKREL_NOTARY_APPLE_ID="you@example.com"
export LOKREL_NOTARY_TEAM_ID="TEAMID"
export LOKREL_NOTARY_PASSWORD="xxxx-xxxx-xxxx-xxxx"
Scripts/release.sh
```
