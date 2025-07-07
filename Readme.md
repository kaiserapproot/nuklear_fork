# Nuklear フォーク版について

このプロジェクトは、[Nuklear](https://github.com/Immediate-Mode-UI/Nuklear) をフォークし、以下の独自拡張・修正を加えたものです。

## 主な違い・追加点

- **Visual Studio 6.0 (VC++6.0) 対応**
    - オリジナルのNuklearではサポートされていない、VC++6.0用のプロジェクトファイルやビルド対応を追加しています。
- **Visual Studio 2022 プロジェクトの追加**
    - 最新のVisual Studio 2022でビルド可能なプロジェクトファイルを追加しています。
- **TCC (Tiny C Compiler) 対応**
    - Windows環境でTCCを用いてビルドできるように対応しています。
    - 特にDirectXおよびOpenGL環境で、glfwを使わずに動作するサンプルやビルド方法を追加しています。
- **プロジェクトファイル・サンプルの追加**
    - `nuklear` フォルダに、OpenGL 1.1（GLFWを使わない）およびGDIのVisual Studio 2022用プロジェクトファイルを追加。
    - `vs6` フォルダに、Visual Studio 6.0用のOpenGL 1.1（GLFWを使わない）およびDirectX9のサンプルプロジェクトを追加。
- **その他**
    - ディレクトリ構成やサンプルの追加・整理など、ビルドや利用の利便性向上を目的とした変更を行っています。

## オリジナルNuklearとの互換性

- 基本的なAPIや機能はオリジナルNuklearと互換性がありますが、上記の追加・修正により一部ビルド方法やサンプル構成が異なります。
- 本プロジェクトは、Nuklearの比較的古いバージョンをベースにしており、最新バージョンのNuklearとは一部仕様や実装が異なる場合があります。
- 詳細は各ディレクトリのReadmeやプロジェクトファイルをご参照ください。

---

# Nuklear Fork Version

This project is a fork of [Nuklear](https://github.com/Immediate-Mode-UI/Nuklear) with the following unique extensions and modifications.

## Main Differences and Additions

- **Visual Studio 6.0 (VC++6.0) Support**
    - Added project files and build support for VC++6.0, which are not supported in the original Nuklear.
- **Visual Studio 2022 Project Files**
    - Added project files for building with the latest Visual Studio 2022.
- **TCC (Tiny C Compiler) Support**
    - Enabled building with TCC on Windows.
    - Especially, added samples and build methods for DirectX and OpenGL environments that do not use glfw.
- **Additional Project Files and Samples**
    - Added Visual Studio 2022 project files for OpenGL 1.1 (without GLFW) and GDI in the `nuklear` folder.
    - Added Visual Studio 6.0 sample projects for OpenGL 1.1 (without GLFW) and DirectX9 in the `vs6` folder.
- **Others**
    - Improved directory structure and added/organized samples to enhance build and usage convenience.

## Compatibility with Original Nuklear

- The basic API and features are compatible with the original Nuklear, but some build methods and sample structures differ due to the above additions and modifications.
- This project is based on a relatively old version of Nuklear, so there may be some differences in specifications and implementation compared to the latest version.
- For details, please refer to the Readme or project files in each directory.

---

The documentation will be updated as needed with more details and usage instructions.

