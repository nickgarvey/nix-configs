{ config, lib, pkgs, inputs, ... }:

let
  python = pkgs.python3.withPackages (ps: with ps; [
    sentence-transformers
    faiss
    gensim
    numpy
    scikit-learn
    torch
    transformers
    chromadb
    psycopg2
    pgvector
    pymupdf
    praw
    nltk
    fastapi
    uvicorn
    tqdm
    python-dotenv
    requests
    arxiv
    ollama
  ]);

  postgresqlWithPgvector = pkgs.postgresql.withPackages (ps: [
    ps.pgvector
  ]);
in
{
  # PostgreSQL service with pgvector
  services.postgresql = {
    enable = true;
    package = postgresqlWithPgvector;
  };

  # Ollama for local LLM serving
  services.ollama = {
    enable = true;
    environmentVariables = {
      OLLAMA_CONTEXT_LENGTH = "32768";
      OLLAMA_NUM_PARALLEL = "1";
      OLLAMA_MAX_LOADED_MODELS = "1";
    };
  };

  # Docker for chapter 5 deployment
  virtualisation.docker.enable = true;
  users.users.ngarvey.extraGroups = [ "docker" ];

  # User packages
  users.users.ngarvey.packages = [
    python
    pkgs.sqlite
    pkgs.pi-coding-agent
  ];
}
