This package provides a Docker image running Jenkins behind NGINX. It is designed to be deployed to Google Managed VMs using the provided app.yaml configuration file, but could also be deployed to any other platform that supports Docker images.

In its setup, Jenkins is started inside a container, listening to a local port. NGINX is running in front of Jenkins to allow flexibility in creating our health check end point and passing authentication headers.

The reverse-proxy-auth plugin is used by Jenkins to trust the authentication headers passed by NGINX, which receives them from the underlying platform (expected: Google App Engine).

For convenience, $JENKINS_HOME is seeded with content of the /jenkins directory.  Users can add plugins and initial configurations as needed.

This image starts a Jenkins instance with several bundled plugins. In particular, the Google Cloud Backup plugin provides automatic backup and restore functionality. The default configuration when launched to Google Managed VMs will create backup files using Google Cloud Storage. This allows the Jenkins master to retain state despite intentional or accidental restarts of the VM.

This image is packaged with a usage-reporting plugin. By default, the plugin is disabled and does not send any usage reports. Users who choose to opt in to usage reporting may do so by passing the --report_usage flag to the install script.

You must have an existing Google Cloud Project to deploy to that has billing
setup, and you must have these APIs enabled in your project:
- Google Compute Engine
- Google Cloud Storage

If you want to deploy from the source code, run:

    (in the /bundle directory)
    ./build-bundle.sh
    (in the /image directory)
    ./install.sh --project <your project> --build_from_src

If you want to deploy using the pre-built Docker image instead of from the source
code, run:

    (in the /image directory)
    ./install.sh --project <your project>

To see more command line options, run:

    (in the /image directory)
    ./insall.sh --help

If you want to build and push the testing version of Docker image, run:

    (in the /bundle directory)
    ./build.sh

    (in the image directory)
    ./build.sh testing --push_image

However, you must have write permission to the GCR repo where these images are stored in order to do so.
