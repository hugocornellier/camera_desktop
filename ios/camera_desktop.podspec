Pod::Spec.new do |s|
  s.name             = 'camera_desktop'
  s.version          = '1.1.2'
  s.summary          = 'Flutter camera plugin (iOS stub).'
  s.description      = <<-DESC
Flutter camera plugin for desktop platforms. iOS stub for platform declaration.
                       DESC
  s.homepage         = 'https://github.com/hugocornellier/camera_desktop'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Hugo Cornellier' => 'hugo@hugocornellier.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'camera_desktop/Sources/camera_desktop/**/*.{swift,h,m}'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'

  s.resource_bundles = { 'camera_desktop_privacy' => ['camera_desktop/Sources/camera_desktop/PrivacyInfo.xcprivacy'] }

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
  s.swift_version = '5.0'
end
