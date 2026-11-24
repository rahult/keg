'use strict';

/** An error of Keg's, with a word for what went wrong in `code`. */
class KegError extends Error {
  /**
   * @param {string} code
   * @param {string} message
   * @param {unknown} [cause]
   */
  constructor(code, message, cause) {
    super(message, cause === undefined ? undefined : { cause });
    this.name = 'KegError';
    this.code = code;
  }
}

module.exports = { KegError };
