const http = require("http");
const fs = require("fs");
const path = require("path");
const os = require("os");

const MINIKUBE_HOME = path.join(os.homedir(), ".minikube");
const PORT = 8888;

const server = http.createServer((req, res) => {
  console.log(`${new Date().toISOString()} - ${req.method} ${req.url}`);

  const urlPath = req.url;

  let filePath = null;

  if (urlPath === "/minikube/ca.crt") {
    filePath = path.join(MINIKUBE_HOME, "ca.crt");
  } else if (urlPath === "/minikube/client.crt") {
    filePath = path.join(MINIKUBE_HOME, "profiles/minikube/client.crt");
  } else if (urlPath === "/minikube/client.key") {
    filePath = path.join(MINIKUBE_HOME, "profiles/minikube/client.key");
  } else if (urlPath === "/minikube-b/ca.crt") {
    filePath = path.join(MINIKUBE_HOME, "ca.crt");
  } else if (urlPath === "/minikube-b/client.crt") {
    filePath = path.join(MINIKUBE_HOME, "profiles/minikube-b/client.crt");
  } else if (urlPath === "/minikube-b/client.key") {
    filePath = path.join(MINIKUBE_HOME, "profiles/minikube-b/client.key");
  } else if (urlPath === "/minikube-c/ca.crt") {
    filePath = path.join(MINIKUBE_HOME, "ca.crt");
  } else if (urlPath === "/minikube-c/client.crt") {
    filePath = path.join(MINIKUBE_HOME, "profiles/minikube-c/client.crt");
  } else if (urlPath === "/minikube-c/client.key") {
    filePath = path.join(MINIKUBE_HOME, "profiles/minikube-c/client.key");
  } else if (urlPath === "/" || urlPath === "") {
    res.writeHead(200, { "Content-Type": "text/html" });
    res.end(`
      <!DOCTYPE html>
      <html>
      <head><title>Minikube Certificate Server</title></head>
      <body>
        <h1>Minikube Certificate Server</h1>
        <h2>Available Certificates:</h2>
        <h3>minikube</h3>
        <ul>
          <li><a href="/minikube/ca.crt">/minikube/ca.crt</a></li>
          <li><a href="/minikube/client.crt">/minikube/client.crt</a></li>
          <li><a href="/minikube/client.key">/minikube/client.key</a></li>
        </ul>
        <h3>minikube-b</h3>
        <ul>
          <li><a href="/minikube-b/ca.crt">/minikube-b/ca.crt</a></li>
          <li><a href="/minikube-b/client.crt">/minikube-b/client.crt</a></li>
          <li><a href="/minikube-b/client.key">/minikube-b/client.key</a></li>
        </ul>
        <h3>minikube-c</h3>
        <ul>
          <li><a href="/minikube-c/ca.crt">/minikube-c/ca.crt</a></li>
          <li><a href="/minikube-c/client.crt">/minikube-c/client.crt</a></li>
          <li><a href="/minikube-c/client.key">/minikube-c/client.key</a></li>
        </ul>
      </body>
      </html>
    `);
    return;
  } else {
    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("Not Found\n");
    return;
  }

  fs.access(filePath, fs.constants.R_OK, (err) => {
    if (err) {
      console.error(`File not accessible: ${filePath}`);
      res.writeHead(404, { "Content-Type": "text/plain" });
      res.end("File not found\n");
      return;
    }

    fs.readFile(filePath, "utf8", (err, data) => {
      if (err) {
        console.error(`Error reading file: ${err}`);
        res.writeHead(500, { "Content-Type": "text/plain" });
        res.end("Internal Server Error\n");
        return;
      }

      res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
      res.end(data);
    });
  });
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(
    `http://localhost:8888/ in your browser to see available certificates`,
  );
});
