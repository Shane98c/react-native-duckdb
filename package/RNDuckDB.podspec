require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "RNDuckDB"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["repository"]["url"]
  s.license      = package["license"]
  s.authors      = "pranshu"
  s.platforms    = { :ios => min_ios_version_supported }
  s.source       = { :git => package["repository"]["url"], :tag => "#{s.version}" }

  # Build DuckDB from source at pod-install time.
  # Creates DuckDB.xcframework with all configured extensions statically linked.
  # Scripts and duckdb submodule live at the repo root (one level above package/).
  # Pass the app's Podfile directory so the build script can find the app's
  # extension config regardless of where this package physically lives —
  # node_modules symlinks resolve to the real checkout, so the script's own
  # relative probes can't be trusted (see build-duckdb-ios.sh).
  app_ios_dir = (Pod::Config.instance.installation_root.to_s rescue "")
  s.prepare_command = <<-CMD
    RNDUCKDB_APP_IOS_DIR="#{app_ios_dir}" bash ../scripts/build-duckdb-ios.sh #{min_ios_version_supported}
  CMD

  s.source_files = [
    # Objective-C++ platform init
    "ios/**/*.{h,hpp,m,mm}",
    # C++ implementation
    "cpp/**/*.{h,hpp,c,cpp}",
  ]

  # Vendor the pre-built DuckDB xcframework.
  # The build script copies it into package/ so it's within the pod source tree
  # (CocoaPods ignores vendored_frameworks outside PODS_TARGET_SRCROOT).
  s.vendored_frameworks = "DuckDB.xcframework"

  # DuckDB headers and our C++ headers must be private — the massive DuckDB C++
  # headers break Swift/C++ interop if exposed through the umbrella header.
  s.private_header_files = [
    "cpp/**/*.{h,hpp}"
  ]

  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'CLANG_CXX_LIBRARY' => 'libc++',
    :WARNING_CFLAGS => '-Wno-shorten-64-to-32 -Wno-comma -Wno-unreachable-code -Wno-conditional-uninitialized -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-sign-compare -Wno-unused-parameter -Wno-missing-field-initializers',
    "HEADER_SEARCH_PATHS" => '"$(PODS_TARGET_SRCROOT)/../duckdb/src/include" "$(PODS_TARGET_SRCROOT)/cpp"',
  }

  load 'nitrogen/generated/ios/RNDuckDB+autolinking.rb'
  add_nitrogen_files(s)

  # Override nitrogen's public headers: only keep the Swift-Cxx bridge as public.
  # All other C++ headers (DuckDB, HybridDuckDBSpec, etc.) must be private to
  # prevent them from appearing in the umbrella header, where they break
  # Xcode 26's C++ module system.
  s.public_header_files = [
    "nitrogen/generated/ios/RNDuckDB-Swift-Cxx-Bridge.hpp",
  ]
  current_private = Array(s.attributes_hash['private_header_files'])
  s.private_header_files = current_private + [
    "nitrogen/generated/shared/**/*.{h,hpp}",
    "nitrogen/generated/ios/c++/**/*.{h,hpp}",
  ]

  # Extensions with native dependencies are statically linked into the
  # xcframework but still need system frameworks/libraries at link time.
  ext_meta = File.join(__dir__, ".duckdb-extensions.json")
  if File.exist?(ext_meta)
    ext_info = JSON.parse(File.read(ext_meta)) rescue {}
    frameworks = []
    libraries = []
    if ext_info["httpfs"]
      # OpenSSL + libcurl need Security/SystemConfiguration and system zlib
      frameworks += ["Security", "SystemConfiguration"]
      libraries += ["z"]
    end
    if ext_info["spatial"]
      # GDAL links the system iconv (vcpkg's libiconv is a stub on Apple platforms)
      libraries += ["iconv", "z"]
    end
    s.frameworks = frameworks.uniq unless frameworks.empty?
    s.libraries = libraries.uniq unless libraries.empty?
  end

  install_modules_dependencies(s)
end
