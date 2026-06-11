FROM node:18-bullseye

RUN apt-get -yqq update && \
    apt-get -yqq install libboost-all-dev libsodium-dev

RUN npm install -g pm2

WORKDIR /site

COPY package.json ./

ARG CACHEBUST=1
RUN npm install

CMD ["pm2-runtime", "start", "ecosystem.config.js", "--only", "site"]
