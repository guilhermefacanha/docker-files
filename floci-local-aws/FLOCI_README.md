# Floci Local AWS Environment

/resume 009244fe-a957-435e-acc4-dcf747e91f77

This project provides a `docker-compose` setup for a local AWS environment using Floci and a PostgreSQL database, along with pgAdmin for database management. This setup is ideal for developing and testing applications that interact with AWS services and a PostgreSQL database without incurring AWS costs.

## Prerequisites

Before you begin, ensure you have the following installed:

*   **Docker Desktop**: [https://www.docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop)
*   **AWS CLI (optional, but recommended)**: For interacting with Floci's local AWS services. [https://aws.amazon.com/cli/](https://aws.amazon.com/cli/)
*   **DBeaver (or any other PostgreSQL client)**: For connecting to the PostgreSQL database. [https://dbeaver.io/download/](https://dbeaver.io/download/)

## Setup Instructions

1.  **Clone the repository (if you haven't already):**

    ```bash
    git clone https://github.com/floci-io/docker-files-guilhermefacanha.git
    cd docker-files-guilhermefacanha/floci-local-aws
    ```

2.  **Start the Docker containers:**

    Navigate to the `floci-local-aws` directory and run the following command:

    ```bash
    docker-compose up -d
    ```

    This command will:
    *   Start a `floci` container, which will act as the gateway for local AWS services on `http://localhost:4566`.
    *   Start a `postgres` container, exposing the PostgreSQL database on `localhost:5432`.
    *   Start a `pgadmin` container, accessible via your web browser at `http://localhost:8080`.

3.  **Verify services are running:**

    You can check the status of your containers with:

    ```bash
    docker-compose ps
    ```
    Setup env vars
    ```bash 
    
    export AWS_ENDPOINT_URL="http://localhost:4567"
    export AWS_ACCESS_KEY_ID="test"
    export AWS_SECRET_ACCESS_KEY="test"
    export AWS_DEFAULT_REGION="us-east-1"
    
    
    ```

## Connecting to PostgreSQL with DBeaver

1.  **Open DBeaver.**
2.  **Create a New Connection:**
    *   Click on "New Database Connection" (the plug icon).
    *   Select "PostgreSQL" and click "Next".
3.  **Connection Settings:**
    *   **Host:** `localhost`
    *   **Port:** `5432`
    *   **Database:** `flocidb`
    *   **Username:** `flociuser`
    *   **Password:** `flocipassword`
4.  **Test Connection:** Click "Test Connection..." to ensure everything is configured correctly. You should see a "Connected" message.
5.  **Finish:** Click "Finish" to save the connection.

You can now browse the `flocidb` database, create tables, and run queries using DBeaver.

## Accessing pgAdmin

pgAdmin is a web-based administration tool for PostgreSQL.

1.  Open your web browser and navigate to `http://localhost:8080`.
2.  **Login:**
    *   **Email:** `admin@example.com`
    *   **Password:** `admin`
3.  **Add New Server:**
    *   In the pgAdmin interface, right-click on "Servers" in the left panel and select "Register" -> "Server...".
    *   **General Tab:**
        *   **Name:** `Local PostgreSQL` (or any descriptive name)
    *   **Connection Tab:**
        *   **Host name/address:** `postgres` (This is the service name within the Docker network)
        *   **Port:** `5432`
        *   **Maintenance database:** `flocidb`
        *   **Username:** `flociuser`
        *   **Password:** `flocipassword`
    *   Click "Save".

You can now manage your PostgreSQL database through the pgAdmin web interface.

## Interacting with Local AWS Services via Floci

You can use the AWS CLI to interact with the local AWS services provided by Floci.

**Example: Listing S3 buckets**

```bash
aws s3 ls --endpoint-url=http://localhost:4566
```

**Example: Creating an SQS queue**

```bash
aws sqs create-queue --queue-name my-test-queue --endpoint-url=http://localhost:4566
```

## Stopping the Environment

To stop and remove the Docker containers, volumes, and network, run:

```bash
docker-compose down -v
```

The `-v` flag will also remove the named volume (`postgres-data`), which means your PostgreSQL data will be deleted. If you want to keep the data for future sessions, omit the `-v` flag.
