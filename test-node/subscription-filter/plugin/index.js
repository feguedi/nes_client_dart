const Nes = require('@hapi/nes')
const { validate } = require('../helpers')

exports.strategies = {
    name: 'example-strategies',
    version: '1.0.0',
    async register(server, options) {
        server.auth.strategy('simple', 'basic', { validate })
    }
}

exports.hapiNesPlugin = {
    name: 'hapines-subscription-filter',
    version: '1.0.0',
    plugin: Nes,
    options: {
        auth: {
            timeout: 20000,
            index: true,
            route: {
                strategy: 'simple'
            }
        },
        async onConnection(socket) {
            console.log('Hay un conectado')
            await socket.send(`ID: ${socket.id}`)
            if (socket.auth.isAuthenticated) {
                console.log(`Conectado ${socket.auth.credentials.name} (${socket.auth.credentials.id})`)
            } else {
                socket.disconnect()
            }
        },
        onDisconnection(socket) {
            const nombre = socket.auth.isAuthenticated ? `${socket.auth.credentials.name}` : socket.id
            console.log('Conexión cerrada de', nombre)
        },
        // async onMessage(socket, message) {
        //     return message
        // }
    },
    async register(server, options) {
        
        // Set up subscription

        server.subscription('/items', {
            filter: (path, message, options) => {
                return (message.updater !== options.credentials.username)
            }
        })

    }
}
