<img align="right" width="250" height="47" src="media/Gematik_Logo_Flag.png"/> <br/> 

# fhir-package-initializer

<details>
  <summary>Table of Contents</summary>
  <ol>
    <li>
      <a href="#about-the-project">About The Project</a>
      <ul>
        <li><a href="#release-notes">Release Notes</a></li>
      </ul>
    </li>
    <li>
      <a href="#getting-started">Getting Started</a>
      <ul>
        <li><a href="#prerequisites">Prerequisites</a></li>
        <li><a href="#installation">Installation</a></li>
      </ul>
    </li>
    <li><a href="#usage">Usage</a></li>
    <li><a href="#security-policy">Security Policy</a></li>
    <li><a href="#contributing">Contributing</a></li>
    <li><a href="#license">License</a></li>
    <li><a href="#contact">Contact</a></li>
  </ol>
</details>

## About The Project

A lightweight, containerized utility designed to download and provision FHIR packages onto the file system prior to application startup. This tool is specifically engineered for use as a Kubernetes initContainer or sidecar, enabling seamless pre-deployment of FHIR implementation guides, profiles, and resources.

### Release Notes

See [ReleaseNotes.md](./ReleaseNotes.md) for all information regarding the (newest) releases.

## Getting Started

### Prerequisites

The project requires Docker.

### Installation

The Project can be built with the following command:

```sh
docker build -t europe-west3-docker.pkg.dev/gematik-all-infra-prod/demis-dev/fhir-package-initializer:latest .
```

## Usage

Deploy as an initContainer or as a sidecar in your Kubernetes microservices architecture to pre-populate FHIR profiles and validation resources, 
ensuring your FHIR-enabled services have immediate access to required packages without network dependencies during runtime.

Alternatively, use the Docker image as a base for your Java microservice. 
In this scenario, the Java application will start only after the FHIR packages have been downloaded and processed, 
ensuring all required profiles are available before application startup.

### Parameters

**Required**
- `PACKAGE_NAME`: Name of the FHIR package to be downloaded (e.g., `hl7.fhir.r4.core`).
- `PACKAGE_VERSIONS`: Comma-separated list of versions to be downloaded (e.g., `4.0.1,4.0.2`). The entrypoint initializes each version, in parallel when multiple are provided.

**Optional**
- `TARGET_DIR`: Directory where the FHIR package will be extracted. Default is `/tmp/fhir-profiles`. Creates directory with version name and subfolder `Fhir` (e.g., `/tmp/fhir-profiles/4.0.1/Fhir`).
- `CONFIG_OPTION_PACKAGE_REGISTRY_URL`: URL of the FHIR package registry. Default is `http://package-registry.demis.svc.cluster.local`. 
- `CONFIG_OPTION_PACKAGE_REGISTRY_PORT`: Port of the FHIR package registry. Default is `8080`.
- `FEATURE_FLAG_PACKAGE_REGISTRY_ENABLED`: When building a Java microservice using this Docker image as the base, set this feature flag to `true` to enable FHIR package initialization during container startup. Default is `false`.

### Synchronization through signaling file

The utility always creates a signaling file named `.data-ready` in the profile directory (above the `Fhir` folder) upon completion of the provisioning process; 
this file is particularly relevant when using the tool as a sidecar, as it indicates that all data is ready for consumption.

### Continuous Integration and Delivery

The project contains Jenkins Pipelines to perform automatic build and scanning (`ci.jenkinsfile`) and release (based on retagging of the given Git Tag, `release.jenkinsfile`).
Please adjust the variable values defined at the beginning of the pipelines!

For both the pipelines, you need to create a first initial Release Version in JIRA, so it can be retrieved from Jenkins with the Jenkins Shared Library functions.

**BEWARE**: The Release Pipeline requires a manual configuration of the parameters over the Jenkins UI, defining a JIRA Release Version plugin and naming it `JIRA_RELEASE_VERSION`.
The Information such as Project Key and Regular Expression depends on the project and must be correctly configured.

## Security Policy
If you want to see the security policy, please check our [SECURITY.md](.github/SECURITY.md).

## Contributing
If you want to contribute, please check our [CONTRIBUTING.md](.github/CONTRIBUTING.md).

## License

Copyright 2023-2025 gematik GmbH

EUROPEAN UNION PUBLIC LICENCE v. 1.2

EUPL © the European Union 2007, 2016

See the [LICENSE](./LICENSE.md) for the specific language governing permissions and limitations under the License

## Additional Notes and Disclaimer from gematik GmbH

1. Copyright notice: Each published work result is accompanied by an explicit statement of the license conditions for use. These are regularly typical conditions in connection with open source or free software. Programs described/provided/linked here are free software, unless otherwise stated.
2. Permission notice: Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions::
    1. The copyright notice (Item 1) and the permission notice (Item 2) shall be included in all copies or substantial portions of the Software.
    2. The software is provided "as is" without warranty of any kind, either express or implied, including, but not limited to, the warranties of fitness for a particular purpose, merchantability, and/or non-infringement. The authors or copyright holders shall not be liable in any manner whatsoever for any damages or other claims arising from, out of or in connection with the software or the use or other dealings with the software, whether in an action of contract, tort, or otherwise.
    3. The software is the result of research and development activities, therefore not necessarily quality assured and without the character of a liable product. For this reason, gematik does not provide any support or other user assistance (unless otherwise stated in individual cases and without justification of a legal obligation). Furthermore, there is no claim to further development and adaptation of the results to a more current state of the art.
3. Gematik may remove published results temporarily or permanently from the place of publication at any time without prior notice or justification.
4. Please note: Parts of this code may have been generated using AI-supported technology.’ Please take this into account, especially when troubleshooting, for security analyses and possible adjustments.

## Contact
E-Mail to [DEMIS Entwicklung](mailto:demis-entwicklung@gematik.de?subject=[GitHub]%20fhir-package-initializer)
