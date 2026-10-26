import express, { Request, Response } from "express";

const app = express();
const PORT = Number(process.env.PORT) || 3000;

app.use(express.json());

app.get("/", (req: Request, res: Response) => {
  res.status(200).send("Hello from my DevOps project! Version 3 is deployed.");
});

app.get("/health", (req: Request, res: Response) => {
  res.status(200).json({
    status: "ok",
    uptime: process.uptime(),
  });
});

app.get("/environment", (req: Request, res: Response) => {
  res.status(200).json({
    status: "ok",
    environment: process.env.APP_ENV,
  });
});

app.use((req: Request, res: Response) => {
  res.status(404).json({
    message: "Route not found",
  });
});

app.listen(PORT, "0.0.0.0", () => {
  console.log(`Server running at http://localhost:${PORT}`);
});
