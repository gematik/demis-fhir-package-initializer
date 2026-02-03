<img align="right" width="250" height="47" src="media/Gematik_Logo_Flag.png"/> <br/> 

# Release notes FHIR Package Initializer

## Release 1.0.9
- Improved GitHub publish release workflow
- Upgraded OSADL base image to 1.0.6

## Release 1.0.7
- Added GitHub publish release workflow

## Release 1.0.6
- Reduced wait times for istio-proxy

## Release 1.0.5
- Switched to parallel processing for downloading, extracting, and organizing FHIR package files.
- Upgraded OSADL base image to 1.0.5

## Release 1.0.4
- Fixed release pipeline parameter name of default branch
- Upgraded OSADL base image
- Changed names of environment variables:
  - REGISTRY_URL -> CONFIG_OPTION_PACKAGE_REGISTRY_URL
  - REGISTRY_PORT -> CONFIG_OPTION_PACKAGE_REGISTRY_PORT

## Release 1.0.3
- Removed wget and tar from Dockerfile
- Fixed parameter TARGET_DIR not being applied correctly

## Release 1.0.2

- Initial Release
- Operating modes: Kubernetes initContainer, Docker base image
