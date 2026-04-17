const { PrismaClient } = require('@prisma/client');

// Single shared instance — avoids connection pool exhaustion
const prisma = new PrismaClient();

module.exports = prisma;
