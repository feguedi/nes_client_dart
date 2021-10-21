const Hapi = require('@hapi/hapi')
const Basic = require('@hapi/basic')

const { hapiNesPlugin, strategies } = require('../plugin')

const Server = async () => {
    const server = Hapi.server({
        port: process.env.PORT || 3003,
        host: '0.0.0.0',
    })

    await server.register([Basic, strategies, hapiNesPlugin])

    server.route({
        method: 'GET',
        path: '/',
        config: {
            id: 'hello',
        },
        handler: (request, h) => {
            return `Hello ${request.auth.credentials.name}`;
        }
    })

    return server
}

exports.start = async () => {
    try {
        const server = await Server()    
        await server.start()

        console.log('Servidor en puerto', server.info.uri)

        await server.publish('/items', { id: 5, status: 'complete', updater: 'john' })
        await server.publish('/items', { id: 6, status: 'initial', updater: 'steve' })
    } catch (error) {
        console.error(error)
        process.exit(1)
    }
}
