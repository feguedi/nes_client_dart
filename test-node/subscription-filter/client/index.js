const Nes = require('@hapi/nes')

const client = new Nes.Client('ws://localhost:3003')

const start = async () => {
    try {
        console.log('[antes] ID:', client.id)
        await client.connect({ auth: { headers: { authorization: 'Basic am9objpzZWNyZXQ=' } } })
        console.log('ID:', client.id)

        const handler = (update, flags) => {
            console.log(`UPDATE: ${update}`)
            console.log(`FLAGS: ${flags.toString()}`)
        }

        client.subscribe('/items', handler)
    } catch (error) {
        console.error(error)
    }
}

start()
