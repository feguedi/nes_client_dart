const Bcrypt = require('bcrypt')
const { users } = require('../db')

// Set up HTTP Basic authentication

exports.validate = async (request, username, password) => {

    const user = users[username]
    if (!user) {
        return { isValid: false }
    }

    const isValid = await Bcrypt.compare(password, user.password)
    const  credentials = { id: user.id, name: user.name }
    return { isValid, credentials }
}
