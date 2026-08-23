# Passerelle de federation — Node 22, aucune dependance externe.
# L'image ne contient que le code du service : rien a telecharger au
# demarrage, ce qui est indispensable en reseau ferme.
FROM node:22-alpine

WORKDIR /app
COPY package.json ./
COPY lib ./lib
COPY server.mjs ./

USER node
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD node -e "fetch('http://localhost:8080/federation/v1/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "server.mjs"]
