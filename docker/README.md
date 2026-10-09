# Logos Storage Docker Image

 Logos Storage provides pre-built docker images and they are stored in the [logosstorage/logos-storage-nim](https://hub.docker.com/repository/docker/logosstorage/logos-storage-nim) repository.


## Build

From the repository root:

```sh
docker build -f docker/storage.Dockerfile -t logos-storage .
```

The build installs the pinned Nim/Nimble toolchain and resolves `storage.nimble` into `/opt/nimbledeps` inside the builder. It needs neither a recursive checkout nor a lockfile. Use `--build-arg MAKE_PARALLEL=4` to control compiler parallelism and `--build-arg NIMFLAGS="-d:disableMarchNative"` for additional flags.

The NAT test image uses the same toolchain setup: `make buildNatImage`.

## Run

 We can run Logos Storage Docker image using CLI
 ```shell
 # Default run
 docker run --rm logosstorage/logos-storage-nim

 # Mount local datadir
 docker run -v ./datadir:/datadir --rm logosstorage/logos-storage-nim storage --data-dir=/datadir
 ```

 And Docker Compose
 ```shell
 # Run in detached mode
 docker-compose up -d
 ```


## Arguments

 Docker image is based on the [storage.Dockerfile](storage.Dockerfile) and there is
  ```
  ENTRYPOINT ["/docker-entrypoint.sh"]
  CMD ["storage"]
  ```

 It means that at the image run it will just run `storage` application without any arguments and we can pass them as a regular arguments, by overriding command
 ```shell
 docker run logosstorage/logos-storage-nim storage --api-bindaddr=0.0.0.0 --api-port=8080
 ```


## Environment variables

 We can configure Logos Storage using [Environment variables](../README#environment-variables) and [docker-compose.yaml](docker-compose.yaml) file can be useful as an example.

 We also added a temporary environment variable `NAT_IP_AUTO` to the entrypoint which is set as `false` for releases and ` true` for regular builds. That approach is useful for Dist-Tests.
 ```shell
 # Disable NAT_IP_AUTO for regular builds
 docker run -e NAT_IP_AUTO=false logosstorage/logos-storage-nim
 ```


## Slim
 1. Build the image using `docker build -t logosstorage/logos-storage-nim:latest -f storage.Dockerfile ..`
 2. The docker image can then be minified using [slim](https://github.com/slimtoolkit/slim). Install slim on your path and then run:
    ```shell
    slim # brings up interactive prompt
    >>> build --target status-im/logosstoragesetup --http-probe-off true
    ```
 3. This should output an image with name `status-im/logosstoragesetup.slim`
 4. We can then bring up the image using `docker-compose up -d`.
