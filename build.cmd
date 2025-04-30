@echo off
setlocal enabledelayedexpansion

rem
rem build architecture
rem

if "%1" equ "x64" (
  set ARCH=x64
) else if "%1" equ "arm64" (
  set ARCH=arm64
) else if "%1" neq "" (
  echo Unknown target "%1" architecture!
  exit /b 1
) else if "%PROCESSOR_ARCHITECTURE%" equ "AMD64" (
  set ARCH=x64
) else if "%PROCESSOR_ARCHITECTURE%" equ "ARM64" (
  set ARCH=arm64
)

rem
rem dependencies
rem

where /q git.exe || (
  echo ERROR: "git.exe" not found
  exit /b 1
)

rem
rem get depot tools
rem

set PATH=%CD%\depot_tools;%PATH%
set DEPOT_TOOLS_WIN_TOOLCHAIN=0

if not exist depot_tools (
  call git clone --depth=1 --no-tags --single-branch https://chromium.googlesource.com/chromium/tools/depot_tools.git || exit /b 1
)

rem
rem clone angle source
rem

if "%ANGLE_COMMIT%" equ "" (
  for /f "tokens=1 usebackq" %%F IN (`git ls-remote https://chromium.googlesource.com/angle/angle HEAD`) do set ANGLE_COMMIT=%%F
)

if not exist angle (
  mkdir angle
  pushd angle
  call git init .                                                          || exit /b 1
  call git remote add origin https://chromium.googlesource.com/angle/angle || exit /b 1
  popd
)

pushd angle

if exist build (
  pushd build
  call git reset --hard HEAD
  popd
)

call git fetch origin %ANGLE_COMMIT% || exit /b 1
call git checkout --force FETCH_HEAD || exit /b 1

python.exe scripts\bootstrap.py || exit /b 1

"C:\Program Files\Git\usr\bin\sed.exe" -i.bak -e "/'third_party\/catapult'\: /,+3d" -e "/'third_party\/dawn'\: /,+3d" -e "/'third_party\/llvm\/src'\: /,+3d" -e "/'third_party\/SwiftShader'\: /,+3d" -e "/'third_party\/VK-GL-CTS\/src'\: /,+3d" -e "s/'tools\/rust\/update_rust.py'/'-c',''/" DEPS || exit /b 1
call gclient sync -f -D -R || exit /b 1

popd

rem
rem build angle
rem

pushd angle

call git apply ..\angle.patch --ignore-whitespace --whitespace=nowarn || exit /b 1
pushd build
call git apply ..\..\build.patch --ignore-whitespace --whitespace=nowarn || exit /b 1
popd

call gn gen out/%ARCH% --args="target_cpu=""%ARCH%"" angle_build_all=false is_debug=false angle_has_frame_capture=false angle_enable_gl=false angle_enable_vulkan=false angle_enable_wgpu=false angle_enable_d3d9=false angle_enable_null=false angle_is_winappsdk=true is_component_build=false winappsdk_dir=""%WINDOWSAPP_SDK_DIR%"" " || exit /b 1
"C:\Program Files\Git\usr\bin\sed.exe" -i.bak -e "s/\/MD/\/MT/" build\config\win\BUILD.gn || exit /b 1
call autoninja -C out/%ARCH% libEGL libGLESv2 || exit /b 1

popd

rem *** prepare output folder ***

mkdir angle-%ARCH%
mkdir angle-%ARCH%\bin
mkdir angle-%ARCH%\lib
mkdir angle-%ARCH%\include

echo %ANGLE_COMMIT% > angle-%ARCH%\commit.txt

copy /y angle\out\%ARCH%\libEGL.dll         angle-%ARCH%\bin 1>nul 2>nul
copy /y angle\out\%ARCH%\libGLESv2.dll      angle-%ARCH%\bin 1>nul 2>nul

copy /y angle\out\%ARCH%\libEGL.dll.pdb         angle-%ARCH%\bin\libEGL.pdb 1>nul 2>nul
copy /y angle\out\%ARCH%\libGLESv2.dll.pdb      angle-%ARCH%\bin\libGLESv2.pdb 1>nul 2>nul

copy /y angle\out\%ARCH%\libEGL.dll.lib       angle-%ARCH%\lib\libEGL.lib 1>nul 2>nul
copy /y angle\out\%ARCH%\libGLESv2.dll.lib    angle-%ARCH%\lib\libGLESv2.lib 1>nul 2>nul

xcopy /D /S /I /Q /Y angle\include\KHR   angle-%ARCH%\include\KHR   1>nul 2>nul
xcopy /D /S /I /Q /Y angle\include\EGL   angle-%ARCH%\include\EGL   1>nul 2>nul
xcopy /D /S /I /Q /Y angle\include\GLES  angle-%ARCH%\include\GLES  1>nul 2>nul
xcopy /D /S /I /Q /Y angle\include\GLES2 angle-%ARCH%\include\GLES2 1>nul 2>nul
xcopy /D /S /I /Q /Y angle\include\GLES3 angle-%ARCH%\include\GLES3 1>nul 2>nul

copy /y angle\include\angle_windowsstore.h    angle-%ARCH%\include\angle_windowsstore.h 1>nul 2>nul

del /Q /S angle-%ARCH%\include\*.clang-format angle-%ARCH%\include\*.md 1>nul 2>nul

rem
rem Done!
rem
