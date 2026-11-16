Pod::Spec.new do |s|
  s.name           = 'NativeMMKV'
  s.version        = '1.0.0'
  s.summary        = 'Reads and writes MMKV stores from Swift through swift-mmkv.'
  s.description    = 'The native half of the swift-mmkv end-to-end test app.'
  s.author         = 'swift-mmkv'
  s.homepage       = 'https://github.com/Tencent/MMKV'
  s.license        = 'MIT'
  s.platforms      = { :ios => '16.0' }
  s.source         = { :git => '' }
  s.swift_version  = '5.9'
  s.static_framework = true

  s.dependency 'ExpoModulesCore'
  s.source_files = '**/*.swift'

  # The package under test, straight from this repository's root.
  spm_dependency(
    s,
    url: File.expand_path('../../../..', __dir__),
    requirement: { :kind => 'upToNextMajorVersion', :minimumVersion => '0.0.0' },
    products: ['SwiftMMKV']
  )
end
